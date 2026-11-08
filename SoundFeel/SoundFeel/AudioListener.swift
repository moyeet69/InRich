import AVFoundation

enum ListenerError: LocalizedError {
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone is available."
        }
    }
}

/// Reads the built-in microphone with the smallest buffers iOS allows and hands
/// every ~5 ms slice to `onSlice` (on the audio thread). Nothing is recorded.
final class AudioListener {
    /// Called on the real-time audio thread.
    var onSlice: ((SliceEnergy) -> Void)?

    /// True when reading through a standard tap (~100 ms chunks) instead of the 5 ms sink.
    private(set) var usingTap = false
    /// e.g. "iPhone Microphone · 48000 Hz · 1 ch", for the meter.
    private(set) var inputDescription = "—"

    /// Recreated on every start, after the session is set up, so the input node
    /// is bound to the record-capable route rather than the launch-time default.
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?

    /// Must run before the haptic engine starts, because haptics share this session.
    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement turns off the voice processing and auto gain that would flatten the dynamics.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        // Without this, iOS silences the Taptic Engine while the mic is in use.
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        // Prefer the built-in mic, even if headphones with a mic are connected.
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    func start(usingTap: Bool = false) throws {
        self.usingTap = usingTap
        try startEngine()
    }

    /// Rebuilds the mic graph without touching the audio session (which haptics share).
    func restart(usingTap: Bool) throws {
        tearDownEngine()
        self.usingTap = usingTap
        try startEngine()
    }

    func stop() {
        tearDownEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.isInputAvailable else { throw ListenerError.noMicrophone }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noMicrophone }

        let port = session.currentRoute.inputs.first?.portName ?? "Unknown input"
        inputDescription = "\(port) · \(Int(format.sampleRate)) Hz · \(format.channelCount) ch"

        let handler = onSlice
        let splitter = BandSplitter(sampleRate: format.sampleRate) { handler?($0) }

        // Feed the mic into a silent mixer that goes to the speaker. Nothing is heard, but a
        // complete input→output path keeps the hardware I/O running, which drives the mic.
        let mixer = engine.mainMixerNode
        mixer.outputVolume = 0

        if usingTap {
            engine.connect(input, to: mixer, format: format)
            input.installTap(onBus: 0, bufferSize: 256, format: format) { buffer, _ in
                if let data = buffer.floatChannelData?[0] {
                    splitter.process(data, count: Int(buffer.frameLength))
                }
            }
        } else {
            // A sink node gets buffers at the hardware I/O size (~5 ms), unlike a tap (~100 ms).
            let sink = AVAudioSinkNode { _, frameCount, bufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
                if let data = buffers.first?.mData {
                    splitter.process(data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
                }
                return noErr
            }
            engine.attach(sink)
            engine.connect(input, to: [
                AVAudioConnectionPoint(node: sink, bus: 0),
                AVAudioConnectionPoint(node: mixer, bus: mixer.nextAvailableInputBus),
            ], fromBus: 0, format: format)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Route or sample-rate change (e.g. headphones plugged in): rebuild the graph.
            guard let self else { return }
            try? self.restart(usingTap: self.usingTap)
        }
    }

    private func tearDownEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
