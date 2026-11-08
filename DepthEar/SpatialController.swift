import ARKit
import Foundation
import simd

/// Everything the UI shows, captured on the control queue at 5 Hz.
struct Readout {
    var distance: Float?
    /// Head-relative, as rendered. Positive = right / up.
    var azimuthDeg: Float?
    var elevationDeg: Float?
    var clickRateHz: Double
    var depthFPS: Double
    var depthSource: DepthSource
    var samplesInCone: Int
    var trackingProblem: String?
    var depthStale: Bool
    var head: HeadTrackingStatus
    var headAngles: HeadAngles?
    var predictionHorizonMs: Double?
    var usingHeadTracking: Bool
    var output: OutputRoute
    var pipelineMessage: String?
    /// Compass bearing (degrees from true north, clockwise) of the listener's
    /// forward direction: the head when head tracking is live, else the phone.
    var headBearingDeg: Double?
    /// Compass bearing the phone (worn on the chest) points along.
    var phoneBearingDeg: Double?
}

/// Ties depth, head tracking and rendering together on one serial queue.
///
/// World anchoring: the target lives in ARKit world coordinates. The listener
/// sits at the phone's position. Its orientation is
///     q_world = q_anchor ⊗ q_head
/// where q_head is the predicted headphone rotation since the last recenter,
/// and q_anchor is the phone's heading captured at that same recenter. So at
/// recenter, "head forward" means "where the phone points". After that, head
/// turns move the listener while the source stays fixed in the room.
final class SpatialController {
    private static let tickInterval: DispatchTimeInterval = .milliseconds(10)   // 100 Hz
    private static let publishEveryTicks = 20                                    // 5 Hz
    private static let depthStaleAfter: TimeInterval = 0.5
    /// Cue gain multiplier while speech is playing.
    private static let duckedGain: Float = 0.3

    private let queue = DispatchQueue(label: "depthear.control", qos: .userInteractive)
    private let tunables: Locked<TunableValues>
    private let depth: DepthPipeline
    private let head = HeadTracker()
    private let renderer: SpatialRenderer

    /// Delivered on the main queue.
    var onReadout: ((Readout) -> Void)?

    /// For the camera preview.
    var arSession: ARSession { depth.session }
    var overlayTarget: Locked<SIMD3<Float>?> { depth.overlayTarget }

    // Touched only on `queue`.
    private var timer: DispatchSourceTimer?
    private var latestDepth: DepthResult?
    private var anchorHeading: Float = 0
    private var centered = false
    private var tickCount = 0
    private var pipelineMessage: String?
    private var ducked = false

    /// Create on the main thread (CMHeadphoneMotionManager and ARSession).
    init(tunables: Locked<TunableValues>) {
        self.tunables = tunables
        depth = DepthPipeline(tunables: tunables)
        renderer = SpatialRenderer(queue: queue)
        depth.onResult = { [weak self] result in
            self?.queue.async { self?.latestDepth = result }
        }
        depth.onError = { [weak self] message in
            self?.queue.async { self?.pipelineMessage = message }
        }
    }

    // MARK: Sonification

    func start(completion: @escaping (Error?) -> Void) {
        queue.async {
            do {
                try self.renderer.start()
            } catch {
                DispatchQueue.main.async { completion(error) }
                return
            }
            self.latestDepth = nil
            self.centered = false
            self.pipelineMessage = nil
            DispatchQueue.main.async {
                self.head.start()
                self.depth.start()
                self.queue.async { self.startTimer() }
                completion(nil)
            }
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.depth.stop()
            self.head.stop()
        }
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.renderer.stop()
            self.latestDepth = nil
        }
    }

    /// Completion receives a sentence suitable for a VoiceOver announcement.
    func recenter(completion: @escaping (String) -> Void) {
        queue.async {
            let message = self.performRecenter()
            DispatchQueue.main.async { completion(message) }
        }
    }

    /// Lowers the cue while speech is playing.
    func setDucked(_ ducked: Bool) {
        queue.async { self.ducked = ducked }
    }

    // MARK: Latency test

    /// Audio only: listener at the origin facing -z, source 1 m straight ahead.
    func startLatencyTest(completion: @escaping (Error?) -> Void) {
        queue.async {
            do {
                try self.renderer.start()
                self.renderer.update(listenerPosition: .zero, listenerOrientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                     sourcePosition: SIMD3(0, 0, -1), clickRateHz: 0)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func playTestClick() {
        queue.async { self.renderer.playTestClick() }
    }

    func stopLatencyTest() {
        queue.async { self.renderer.stop() }
    }

    // MARK: Control loop

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func performRecenter() -> String {
        guard let heading = latestDepth?.heading else {
            return "Cannot recenter yet. Point the phone forward, roughly level."
        }
        anchorHeading = heading
        centered = head.recenter()
        return centered ? "Recentered." : "Recentered to the phone only. No head-tracking data."
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let values = tunables.get()
        tickCount += 1

        // First recenter happens automatically once both sensors are live, and
        // again after the AirPods reconnect.
        let headLiveness = head.liveness(at: now)
        if headLiveness.receiving, !headLiveness.centered || !centered, latestDepth?.heading != nil {
            _ = performRecenter()
        }

        let pose = centered
            ? head.pose(at: now, latency: values.latencyMs / 1000, deadband: radians(Float(values.deadbandDeg)),
                        flipHorizontalAxes: values.flipHeadphoneHorizontalAxes)
            : nil

        let depthResult = latestDepth
        let depthStale = depthResult.map { now - $0.timestamp > Self.depthStaleAfter } ?? true

        var distance: Float?
        var azimuth: Float?
        var elevation: Float?
        var rate = 0.0
        var bearing: Double?
        let gain = Float(values.cueVolume) * (ducked ? Self.duckedGain : 1)

        if let depthResult, !depthStale {
            let orientation: simd_quatf
            if let pose {
                orientation = headingRotation(anchorHeading) * pose.relative
            } else {
                // No head tracking: assume the head faces where the phone points.
                orientation = headingRotation(depthResult.heading ?? anchorHeading)
            }

            bearing = Self.compassBearing(orientation)

            var source: SIMD3<Float>?
            if let target = depthResult.target {
                let offset = target - depthResult.cameraPosition
                let local = orientation.inverse.act(offset)
                distance = simd_length(offset)
                azimuth = degrees(atan2(local.x, -local.z))
                elevation = degrees(atan2(local.y, simd_length(SIMD2(local.x, local.z))))
                let d = distance ?? DepthRange.farMeters
                // Quiet zone: nothing to hear when nothing is close.
                if Double(d) <= values.silentBeyondMeters {
                    rate = RateMapping.rateHz(distance: d, values: values)
                    source = target
                }
            }
            // EXTENSION POINT (Sonifier): a multi-source renderer takes [SpatialTarget]
            // and the same listener pose here.
            renderer.update(listenerPosition: depthResult.cameraPosition, listenerOrientation: orientation,
                            sourcePosition: source, clickRateHz: rate, sound: values.cueSound, gain: gain)
        } else {
            renderer.update(listenerPosition: .zero, listenerOrientation: headingRotation(anchorHeading),
                            sourcePosition: nil, clickRateHz: 0)
        }

        guard tickCount % Self.publishEveryTicks == 0 else { return }
        let readout = Readout(
            distance: distance,
            azimuthDeg: azimuth,
            elevationDeg: elevation,
            clickRateHz: rate,
            depthFPS: depthStale ? 0 : depthResult?.framesPerSecond ?? 0,
            depthSource: depthResult?.source ?? (DepthPipeline.hasLiDAR ? .lidar : .featurePoints),
            samplesInCone: depthResult?.samplesInCone ?? 0,
            trackingProblem: depthResult?.trackingProblem,
            depthStale: depthStale,
            head: head.status(at: now),
            headAngles: pose?.angles,
            predictionHorizonMs: pose.map { $0.horizon * 1000 },
            usingHeadTracking: pose != nil,
            output: AudioSessionConfig.currentOutput(),
            pipelineMessage: pipelineMessage,
            headBearingDeg: bearing,
            // DepthResult.heading turns -z towards -x (left) as it grows;
            // compass bearings grow clockwise.
            phoneBearingDeg: depthStale ? nil : depthResult?.heading.map { PlaceGuide.wrap(degrees(-Double($0))) }
        )
        DispatchQueue.main.async { [weak self] in self?.onReadout?(readout) }
    }

    /// World frame is north-aligned (DepthPipeline uses .gravityAndHeading):
    /// north = -z, east = +x. nil when looking nearly straight up or down.
    private static func compassBearing(_ orientation: simd_quatf) -> Double? {
        let forward = orientation.act(SIMD3<Float>(0, 0, -1))
        guard simd_length(SIMD2(forward.x, forward.z)) > 0.4 else { return nil }
        let bearing = degrees(Double(atan2(forward.x, -forward.z)))
        return bearing < 0 ? bearing + 360 : bearing
    }
}
