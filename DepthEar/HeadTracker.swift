import CoreMotion
import simd

/// Predicted head orientation relative to the recentered pose, in ARKit's
/// head-local convention (x right, y up, -z forward).
struct HeadPose {
    var relative: simd_quatf
    var angles: HeadAngles
    /// Age of the CoreMotion sample the prediction was made from.
    var sampleAge: TimeInterval
    /// Total extrapolation: calibrated latency + sample age.
    var horizon: TimeInterval
}

struct HeadTrackingStatus: Equatable {
    /// CMHeadphoneMotionManager.isDeviceMotionAvailable.
    var supported: Bool
    var authorization: CMAuthorizationStatus
    var connected: Bool
    /// A sample arrived within the last `HeadTracker.staleAfter` seconds.
    var receiving: Bool
    var sampleRateHz: Double
    var sensorLocation: String?
    /// Mean prediction error divided by mean no-prediction error, measured
    /// while the head is turning. Below 1 means prediction helps. nil until
    /// enough movement has been seen.
    var predictionErrorRatio: Double?
    var error: String?
    /// Updates were started more than 3 s ago and nothing has arrived.
    var silentSinceStart: Bool
    var centered: Bool
}

/// Owns CMHeadphoneMotionManager and turns its samples into a
/// latency-compensated listener orientation.
///
/// Prediction: the requested model is psi_hat(t + dt) = psi(t) + psi_dot(t)·dt
/// for yaw, pitch and roll. CoreMotion reports rotationRate as a body-frame
/// angular velocity, not as Euler-angle derivatives, so the same first-order
/// extrapolation is applied on the quaternion: q_hat = q ⊗ exp(½·ω·dt). For a
/// level head this is identical to the per-axis formula. With the head pitched
/// it stays correct where the per-axis version would mix yaw into roll.
final class HeadTracker: NSObject, CMHeadphoneMotionManagerDelegate {
    static let staleAfter: TimeInterval = 0.5
    /// Sample age beyond this is not extrapolated further.
    static let maxAgeCompensation: TimeInterval = 0.1

    private let manager = CMHeadphoneMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "depthear.head-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    private struct Sample {
        var attitude: simd_quatd
        var rate: SIMD3<Double>
        var timestamp: TimeInterval
        var location: CMDeviceMotion.SensorLocation
    }

    private struct State {
        var startedAt: TimeInterval = 0
        var latest: Sample?
        var reference: simd_quatd?
        var connected = false
        var sampleRateHz: Double = 0
        var predictedError: Double = 0
        var heldError: Double = 0
        var scoredSamples = 0
        var error: String?
    }

    private let state = Locked(State())

    var isSupported: Bool { manager.isDeviceMotionAvailable }

    func start() {
        state.set(State(startedAt: ProcessInfo.processInfo.systemUptime))
        manager.delegate = self
        guard manager.isDeviceMotionAvailable else { return }
        manager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.state.mutate { $0.error = error.localizedDescription }
            }
            if let motion {
                self.ingest(motion)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        state.mutate { $0.latest = nil }
    }

    /// The current raw attitude becomes "facing forward, head level".
    /// Returns false if no sample has arrived yet.
    func recenter() -> Bool {
        state.mutate { st in
            guard let latest = st.latest else { return false }
            st.reference = latest.attitude
            return true
        }
    }

    func pose(at now: TimeInterval, latency: TimeInterval, deadband: Float, flipHorizontalAxes: Bool) -> HeadPose? {
        let (sample, reference) = state.mutate { ($0.latest, $0.reference) }
        guard let sample, let reference else { return nil }
        let age = max(0, now - sample.timestamp)
        guard age < Self.staleAfter else { return nil }

        let horizon = latency + min(age, Self.maxAgeCompensation)
        let predicted = sample.attitude * simd_quatd.rotation(rate: sample.rate, over: horizon)
        let relative = Self.headFrame(reference.inverse * predicted, flipHorizontalAxes: flipHorizontalAxes)

        var angles = HeadAngles(relative)
        var snapped = false
        if abs(angles.yaw) < deadband { angles.yaw = 0; snapped = true }
        if abs(angles.pitch) < deadband { angles.pitch = 0; snapped = true }
        return HeadPose(relative: snapped ? angles.quaternion : relative,
                        angles: angles,
                        sampleAge: age,
                        horizon: horizon)
    }

    /// Cheap per-tick check: is fresh data arriving, and is there a reference?
    func liveness(at now: TimeInterval) -> (receiving: Bool, centered: Bool) {
        state.mutate { st in
            (st.latest.map { now - $0.timestamp < Self.staleAfter } ?? false, st.reference != nil)
        }
    }

    func status(at now: TimeInterval) -> HeadTrackingStatus {
        let st = state.get()
        let receiving = st.latest.map { now - $0.timestamp < Self.staleAfter } ?? false
        let ratio: Double? = st.scoredSamples >= 20 && st.heldError > 0 ? st.predictedError / st.heldError : nil
        let location: String?
        switch st.latest?.location {
        case .headphoneLeft?: location = "left earbud"
        case .headphoneRight?: location = "right earbud"
        case .default?: location = "default"
        default: location = nil
        }
        return HeadTrackingStatus(
            supported: manager.isDeviceMotionAvailable,
            authorization: CMHeadphoneMotionManager.authorizationStatus(),
            connected: st.connected || receiving,
            receiving: receiving,
            sampleRateHz: receiving ? st.sampleRateHz : 0,
            sensorLocation: location,
            predictionErrorRatio: ratio,
            error: st.error,
            silentSinceStart: st.latest == nil && now - st.startedAt > 3,
            centered: st.reference != nil
        )
    }

    /// Maps a rotation expressed in CoreMotion's headphone body axes onto
    /// ARKit head-local axes.
    ///
    /// Assumed headphone axes (not documented by Apple; see README): x right,
    /// y forward (out of the nose), z up, i.e. pitch about x, roll about y,
    /// yaw about z. Then ARKit (x, y, z) = (x, z, -y). The flip option selects
    /// x left / y back: ARKit (x, y, z) = (-x, z, y). Both are proper rotations,
    /// so the quaternion's vector part maps the same way as a vector.
    static func headFrame(_ q: simd_quatd, flipHorizontalAxes: Bool) -> simd_quatf {
        let v = q.imag
        let mapped = flipHorizontalAxes ? SIMD3(-v.x, v.z, v.y) : SIMD3(v.x, v.z, -v.y)
        return simd_quatf(ix: Float(mapped.x), iy: Float(mapped.y), iz: Float(mapped.z), r: Float(q.real))
    }

    private func ingest(_ motion: CMDeviceMotion) {
        let cq = motion.attitude.quaternion
        let sample = Sample(
            attitude: simd_normalize(simd_quatd(ix: cq.x, iy: cq.y, iz: cq.z, r: cq.w)),
            rate: SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z),
            timestamp: motion.timestamp,
            location: motion.sensorLocation
        )

        state.mutate { st in
            if let previous = st.latest {
                let dt = sample.timestamp - previous.timestamp
                if dt > 0, dt < 0.2 {
                    st.sampleRateHz = st.sampleRateHz == 0 ? 1 / dt : 0.95 * st.sampleRateHz + 0.05 / dt
                    // Self-check of the prediction model: extrapolate the previous
                    // sample to this one's timestamp and compare against simply
                    // holding it. Only scored above ~30°/s, where it matters.
                    if simd_length(previous.rate) > 0.5 {
                        let predicted = previous.attitude * simd_quatd.rotation(rate: previous.rate, over: dt)
                        st.predictedError = 0.98 * st.predictedError + 0.02 * angularDistance(predicted, sample.attitude)
                        st.heldError = 0.98 * st.heldError + 0.02 * angularDistance(previous.attitude, sample.attitude)
                        st.scoredSamples += 1
                    }
                }
            }
            st.latest = sample
            st.error = nil
        }
    }

    // MARK: CMHeadphoneMotionManagerDelegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        state.mutate { $0.connected = true }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        state.mutate {
            $0.connected = false
            $0.latest = nil
            // The headphone reference frame may change across reconnects.
            $0.reference = nil
        }
    }
}
