import AVFoundation
import CoreHaptics

/// Drives the Taptic Engine with two kinds of signal:
/// a continuous vibration whose strength changes live, and short bursts for beats.
///
/// Not thread-safe: only use it from one serial queue.
final class HapticPlayer {
    /// Called (on an arbitrary thread) when the system resets or stops the engine.
    var onInterrupted: (() -> Void)?
    /// The most recent Core Haptics failure, shown on the meter.
    private(set) var lastError: String?

    private var engine: CHHapticEngine?
    private var continuous: CHHapticAdvancedPatternPlayer?
    private var sentIntensity: Float = 0
    private var sentSharpness: Float = 0.5
    private var isRunning = false

    static var isSupported: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    func start() throws {
        // Sharing the app's audio session lets haptics play while the mic records.
        let engine = try CHHapticEngine(audioSession: .sharedInstance())
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        engine.resetHandler = { [weak self] in self?.onInterrupted?() }
        engine.stoppedHandler = { [weak self] _ in self?.onInterrupted?() }
        try engine.start()
        self.engine = engine
        isRunning = true
        try makeContinuousPlayer()
    }

    /// Restarts after the system reset or stopped the engine.
    func recover() {
        guard isRunning, let engine else { return }
        do {
            try engine.start()
            try makeContinuousPlayer()
            lastError = nil
        } catch {
            // Try again on the next interruption callback.
            lastError = "Restart failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        isRunning = false
        try? continuous?.stop(atTime: CHHapticTimeImmediate)
        continuous = nil
        engine?.stop()
        engine = nil
    }

    /// Sets the live vibration. `intensity` and `sharpness` are 0...1.
    func setContinuous(intensity: Float, sharpness: Float) {
        guard let continuous else { return }
        var params: [CHHapticDynamicParameter] = []
        // Skip tiny changes so we aren't flooding the engine 200 times a second.
        if abs(intensity - sentIntensity) > 0.01 || (intensity == 0 && sentIntensity != 0) {
            params.append(CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0))
            sentIntensity = intensity
        }
        if abs(sharpness - sentSharpness) > 0.03 {
            // Sharpness control is added to the event's base sharpness of 0.5.
            params.append(CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness - 0.5, relativeTime: 0))
            sentSharpness = sharpness
        }
        guard !params.isEmpty else { return }
        do {
            try continuous.sendParameters(params, atTime: CHHapticTimeImmediate)
        } catch {
            lastError = "Live vibration: \(error.localizedDescription)"
        }
    }

    /// A strong ringtone-style buzz: a sharp tap followed by a short full-strength hum.
    func burst(intensity: Float, sharpness: Float, duration: TimeInterval) {
        guard let engine else { return }
        let params = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ]
        let events = [
            CHHapticEvent(eventType: .hapticTransient, parameters: params, relativeTime: 0),
            CHHapticEvent(eventType: .hapticContinuous, parameters: params, relativeTime: 0, duration: duration),
        ]
        do {
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            lastError = "Beat buzz: \(error.localizedDescription)"
        }
    }

    private func makeContinuousPlayer() throws {
        guard let engine else { return }
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
            ],
            relativeTime: 0,
            duration: 30
        )
        let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
        player.loopEnabled = true
        try player.sendParameters(
            [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)],
            atTime: CHHapticTimeImmediate
        )
        try player.start(atTime: CHHapticTimeImmediate)
        continuous = player
        sentIntensity = 0
        sentSharpness = 0.5
    }
}
