import AVFoundation
import PHASE
import simd

enum RendererError: LocalizedError {
    case pipelineUnavailable
    case streamNodeMissing

    var errorDescription: String? {
        switch self {
        case .pipelineUnavailable: return "PHASE spatial pipeline could not be created."
        case .streamNodeMissing: return "PHASE push stream node was not created."
        }
    }
}

/// One PHASESource, one PHASEListener, one click-train stream.
///
/// Every method must be called on `queue`. PHASE does not document which
/// threads its object transforms may be set from, so all PHASE calls are kept
/// on that one serial queue.
///
/// Orientation API: PHASEObject exposes only `transform: simd_float4x4`. There
/// is no quaternion setter. The CoreMotion quaternion is converted to a
/// simd_quatf, remapped to ARKit axes (HeadTracker.headFrame), composed with
/// the world heading anchor, and turned into a rotation matrix here. PHASE's
/// local right/up/forward axes are read at runtime from PHASEObject.right,
/// .up and .forward rather than assumed.
final class SpatialRenderer {
    private static let sampleRate: Double = 48_000
    private static let framesPerBuffer: AVAudioFrameCount = 1024   // 21 ms
    /// Distance-to-rate changes reach the ear up to ~85 ms late through this
    /// queue. Head rotation does not go through it: listener transforms apply
    /// at PHASE's next render.
    private static let buffersInFlight = 4
    private static let streamEventID = "depthear.clicks.event"
    private static let streamNodeID = "depthear.clicks.stream"
    private static let testClickAssetID = "depthear.testclick.asset"
    private static let testClickEventID = "depthear.testclick.event"

    private let queue: DispatchQueue
    private let format: AVAudioFormat
    private let generator = ClickTrainGenerator(sampleRate: SpatialRenderer.sampleRate)
    /// Maps an ARKit-convention rotation onto PHASE's local axes.
    private let basisCorrection: simd_float3x3

    private var engine: PHASEEngine?
    private var listener: PHASEListener?
    private var source: PHASESource?
    private var streamEvent: PHASESoundEvent?
    private var stream: PHASEPushStreamNode?
    private var testClickMixerID: String?
    private var generation = 0

    var isRunning: Bool { engine != nil }

    init(queue: DispatchQueue) {
        self.queue = queue
        format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        // Listener transform columns must be the world directions of PHASE's
        // local right/up/forward. With R the head rotation in ARKit convention
        // (forward = -z), that is R · A · Pᵀ, where A and P hold the ARKit and
        // PHASE local bases as columns. If PHASE forward is -z, A · Pᵀ = I.
        let phaseBasis = simd_float3x3(columns: (PHASEObject.right, PHASEObject.up, PHASEObject.forward))
        let arkitBasis = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1)))
        basisCorrection = arkitBasis * phaseBasis.transpose
    }

    func start() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard engine == nil else { return }
        try AudioSessionConfig.activate()

        let engine = PHASEEngine(updateMode: .automatic)
        // PHASE does the HRTF rendering itself, whatever it thinks the output is.
        engine.outputSpatializationMode = .alwaysUseBinaural
        // Dry direct path only: reverb would blur the transient.
        engine.defaultReverbPreset = .none

        let listener = PHASEListener(engine: engine)
        listener.transform = matrix_identity_float4x4
        if #available(iOS 18.0, *) {
            // PHASE must not rotate the listener by head pose on top of the
            // latency-compensated orientation set below.
            listener.automaticHeadTrackingFlags = []
        }
        try engine.rootObject.addChild(listener)

        let source = PHASESource(engine: engine)
        source.transform = matrix_identity_float4x4
        try engine.rootObject.addChild(source)

        let streamMixer = try Self.makeSpatialMixer()
        let streamDefinition = PHASEPushStreamNodeDefinition(mixerDefinition: streamMixer, format: format, identifier: Self.streamNodeID)
        streamDefinition.normalize = false
        _ = try engine.assetRegistry.registerSoundEventAsset(rootNode: streamDefinition, identifier: Self.streamEventID)

        let streamParameters = PHASEMixerParameters()
        streamParameters.addSpatialMixerParameters(identifier: streamMixer.identifier, source: source, listener: listener)
        let streamEvent = try PHASESoundEvent(engine: engine, assetIdentifier: Self.streamEventID, mixerParameters: streamParameters)
        guard let stream = streamEvent.pushStreamNodes[Self.streamNodeID] else { throw RendererError.streamNodeMissing }

        // One-shot click through the same spatial path, without the push
        // stream's buffer queue. Used by the latency test.
        let clickData = Self.clickData(generator.click)
        _ = try engine.assetRegistry.registerSoundAsset(data: clickData, identifier: Self.testClickAssetID, format: format, normalizationMode: .none)
        let testMixer = try Self.makeSpatialMixer()
        let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: Self.testClickAssetID, mixerDefinition: testMixer)
        sampler.playbackMode = .oneShot
        _ = try engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: Self.testClickEventID)

        try engine.start()
        streamEvent.start(completion: nil)

        self.engine = engine
        self.listener = listener
        self.source = source
        self.streamEvent = streamEvent
        self.stream = stream
        testClickMixerID = testMixer.identifier
        generator.rateHz = 0
        generation += 1
        for _ in 0..<Self.buffersInFlight {
            scheduleNextBuffer(generation: generation)
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation += 1
        generator.rateHz = 0
        streamEvent?.stopAndInvalidate()
        engine?.stop()
        engine = nil
        listener = nil
        source = nil
        streamEvent = nil
        stream = nil
        testClickMixerID = nil
        AudioSessionConfig.deactivate()
    }

    /// `listenerOrientation` is in ARKit convention (x right, y up, -z forward),
    /// world frame. `sourcePosition` nil = silence. `gain` is linear, 0…1.
    func update(listenerPosition: SIMD3<Float>, listenerOrientation: simd_quatf, sourcePosition: SIMD3<Float>?, clickRateHz: Double,
                sound: CueSound = .soft, gain: Float = 1) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let listener, let source else { return }
        let rotation = simd_float3x3(listenerOrientation) * basisCorrection
        listener.transform = Self.transform(rotation: rotation, translation: listenerPosition)
        if let sourcePosition {
            source.transform = Self.transform(rotation: matrix_identity_float3x3, translation: sourcePosition)
        }
        generator.rateHz = sourcePosition == nil ? 0 : clickRateHz
        generator.sound = sound
        generator.gain = gain
    }

    /// Plays one click at `sourcePosition` immediately.
    func playTestClick() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let engine, let listener, let source, let testClickMixerID else { return }
        let parameters = PHASEMixerParameters()
        parameters.addSpatialMixerParameters(identifier: testClickMixerID, source: source, listener: listener)
        guard let event = try? PHASESoundEvent(engine: engine, assetIdentifier: Self.testClickEventID, mixerParameters: parameters) else { return }
        event.start(completion: nil)
    }

    private func scheduleNextBuffer(generation scheduled: Int) {
        guard scheduled == generation, let stream,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.framesPerBuffer),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = Self.framesPerBuffer
        generator.render(into: channel, frameCount: Int(Self.framesPerBuffer))
        stream.scheduleBuffer(buffer: buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.scheduleNextBuffer(generation: scheduled) }
        }
    }

    private static func makeSpatialMixer() throws -> PHASESpatialMixerDefinition {
        guard let pipeline = PHASESpatialPipeline(flags: [.directPathTransmission]) else {
            throw RendererError.pipelineUnavailable
        }
        pipeline.entries[PHASESpatialCategory.directPathTransmission]?.sendLevel = 1.0
        let mixer = PHASESpatialMixerDefinition(spatialPipeline: pipeline)
        // Mild level drop with distance (about 7 dB from 1 m to 5 m) on top of
        // the rate cue; full inverse-distance would bury 5 m targets.
        let distanceModel = PHASEGeometricSpreadingDistanceModelParameters()
        distanceModel.rolloffFactor = 0.5
        mixer.distanceModelParameters = distanceModel
        return mixer
    }

    private static func clickData(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func transform(rotation r: simd_float3x3, translation t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(r.columns.0, 0),
            SIMD4(r.columns.1, 0),
            SIMD4(r.columns.2, 0),
            SIMD4(t, 1)
        ))
    }
}
