import CoreLocation
import CoreMotion

/// Walking or standing still, from the iPhone's motion coprocessor
/// (CMMotionActivityManager, covered by NSMotionUsageDescription), with GPS
/// speed as a fallback when activity data is unavailable or denied.
///
/// Activity classification lags by a few seconds after you start or stop.
/// Use from the main thread.
final class ActivityMonitor {
    /// Above this GPS speed you are walking, below `stoppedSpeed` standing.
    private static let walkingSpeed: CLLocationSpeed = 0.7
    private static let stoppedSpeed: CLLocationSpeed = 0.25
    /// GPS speed must stay low this long before counting as stopped.
    private static let stoppedAfter: TimeInterval = 4

    private(set) var isWalking = false
    /// Called on change.
    var onChange: ((Bool) -> Void)?

    private let manager = CMMotionActivityManager()
    private var usingActivity = false
    private var slowSince: TimeInterval?

    func start() {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() != .denied,
              CMMotionActivityManager.authorizationStatus() != .restricted else { return }
        usingActivity = true
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity, activity.confidence != .low else { return }
            if activity.walking || activity.running {
                self.set(true)
            } else if activity.stationary {
                self.set(false)
            }
            // Automotive, cycling and unknown leave the state as it is.
        }
    }

    func stop() {
        manager.stopActivityUpdates()
        usingActivity = false
        slowSince = nil
    }

    /// GPS fallback; ignored while activity updates are running.
    func noteLocation(_ location: CLLocation) {
        guard !usingActivity || CMMotionActivityManager.authorizationStatus() == .denied,
              location.speed >= 0, location.speedAccuracy >= 0, location.speedAccuracy < 1.5 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if location.speed > Self.walkingSpeed {
            slowSince = nil
            set(true)
        } else if location.speed < Self.stoppedSpeed {
            if slowSince == nil { slowSince = now }
            if let since = slowSince, now - since >= Self.stoppedAfter { set(false) }
        }
    }

    private func set(_ walking: Bool) {
        guard walking != isWalking else { return }
        isWalking = walking
        onChange?(walking)
    }
}
