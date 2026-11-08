import Foundation

/// Turns the stream of 5 ms sound slices into vibration.
///
/// Runs entirely on one serial queue. At start it calibrates: it listens to the room for a
/// moment, then buzzes the motor at full strength to learn how loud its own hum sounds to
/// the mic, and from then on subtracts that hum so the phone doesn't buzz at its own buzz.
final class FeelProcessor {
    struct Snapshot {
        var calibrating: Bool
        /// What's being felt right now, 0...1.
        var level: Float
        /// Beats fired since the last snapshot.
        var beats: Int
        var meter: Meter
    }

    /// What the processor sees, for the on-screen meter. Levels are the loudest slice
    /// since the last snapshot, in dB relative to the mic's maximum (dBFS).
    struct Meter: Equatable {
        /// Raw microphone level.
        var micDb: Float = -120
        /// Level after removing the motor's own hum; this is what's compared to the threshold.
        var soundDb: Float = -120
        var bassDb: Float = -120
        /// The room's recent quietest and loudest levels.
        var floorDb: Float = -70
        var ceilingDb: Float = -30
        /// How loud the motor sounds to the mic at full strength; nil until calibrated.
        var humDb: Float?
        var gateOpen = false
        /// Continuous vibration strength being sent, 0...1.
        var vibration: Float = 0
        var slicesPerSecond: Float = 0
        var hapticError: String?
    }

    var settings: FeelSettings

    private let haptics: HapticPlayer
    private let publish: (Snapshot) -> Void

    private enum Phase { case room, hum, settle, running }
    private var phase = Phase.room
    private var time: Float = 0
    private var phaseStart: Float = 0
    private var roomMean = EnergyMean()
    private var humMean = EnergyMean()
    /// Power the mic hears from our own motor at full strength.
    private var hum = SliceEnergy.zero

    private var loudness = AdaptiveRange()
    private var bassLoudness = AdaptiveRange()
    private var kick = OnsetDetector(threshold: 1.8, refractory: 0.15)
    private var snare = OnsetDetector(threshold: 2.0, refractory: 0.08)
    private var brightness: Float = 0.5
    private var output: Float = 0
    private var lastKick: Float = -1

    /// Recent motor strength, held briefly because the mic hears the hum slightly late.
    private var motorActivity: Float = 0
    private var burstLevel: Float = 0
    private var burstUntil: Float = 0

    private var sincePublish: Float = 0
    private var pendingBeats = 0
    private var window = Meter()
    private var windowSlices = 0

    init(settings: FeelSettings, haptics: HapticPlayer, publish: @escaping (Snapshot) -> Void) {
        self.settings = settings
        self.haptics = haptics
        self.publish = publish
    }

    func process(_ slice: SliceEnergy) {
        let dt = slice.duration
        time += dt
        windowSlices += 1
        window.micDb = max(window.micDb, decibels(slice.total))

        switch phase {
        case .room:
            // Motor off: learn what the room sounds like (skip the first 100 ms while the mic settles).
            if time > 0.1 { roomMean.add(slice) }
            if time >= 0.4 {
                enter(.hum)
                haptics.setContinuous(intensity: 1, sharpness: 0.5)
            }
        case .hum:
            if time - phaseStart > 0.15 { humMean.add(slice) }
            if time - phaseStart >= 0.6 {
                hum = humMean.mean.removing(roomMean.mean, scale: 1)
                haptics.setContinuous(intensity: 0, sharpness: 0.5)
                enter(.settle)
            }
        case .settle:
            if time - phaseStart >= 0.15 { enter(.running) }
        case .running:
            feel(slice, dt: dt)
        }

        sincePublish += dt
        if sincePublish >= 1.0 / 30 {
            var meter = window
            meter.floorDb = loudness.floor
            meter.ceilingDb = loudness.ceiling
            meter.humDb = phase == .settle || phase == .running ? decibels(hum.total) : nil
            meter.slicesPerSecond = Float(windowSlices) / sincePublish
            meter.hapticError = haptics.lastError
            publish(Snapshot(calibrating: phase != .running,
                             level: phase == .running ? max(output, time < burstUntil ? 1 : 0) : 0,
                             beats: pendingBeats,
                             meter: meter))
            sincePublish = 0
            pendingBeats = 0
            window = Meter()
            windowSlices = 0
        }
    }

    private func enter(_ next: Phase) {
        phase = next
        phaseStart = time
    }

    private func feel(_ raw: SliceEnergy, dt: Float) {
        // 1. Remove our own motor hum, scaled to how hard the motor has just been running.
        let motorNow = max(output * settings.strength, time < burstUntil ? burstLevel : 0)
        motorActivity = max(motorNow, motorActivity * max(0, 1 - dt / 0.03))
        let slice = settings.ignoreOwnBuzz
            ? raw.removing(hum, scale: motorActivity * motorActivity)
            : raw

        // 2. Analyze: loudness within the room's recent range, brightness, beats.
        let db = decibels(slice.total)
        let bassDb = decibels(slice.low)
        let audible = db > settings.quietThresholdDb
        let level = loudness.update(db, dt: dt)

        let rawBrightness = min(1, 2 * (slice.high / max(slice.total, 1e-12)).squareRoot())
        brightness += (rawBrightness - brightness) * min(1, dt / 0.05)

        let kickStrength = kick.update(energy: slice.low, time: time, dt: dt)
        let snareStrength = snare.update(energy: slice.high, time: time, dt: dt)

        // 3. Decide, depending on the mode.
        var sharpness: Float
        switch settings.mode {
        case .everySound:
            // Small dead zone near the room's floor so pauses in speech go still.
            let shaped = pow(max(0, (level - 0.12) / 0.88), 0.8)
            smooth(toward: audible ? shaped : 0, attack: 0.008, release: 0.05, dt: dt)
            sharpness = 0.2 + 0.8 * brightness

        case .music:
            let bass = bassLoudness.update(bassDb, dt: dt)
            // Rumble leaves headroom so beats stand out on top of it.
            smooth(toward: audible ? 0.55 * pow(bass, 1.5) : 0, attack: 0.02, release: 0.09, dt: dt)
            sharpness = 0.15

            if audible, let strength = kickStrength {
                fireBeat(intensity: 0.75 + 0.25 * strength, sharpness: 0.35, duration: 0.12)
                lastKick = time
            } else if audible, let strength = snareStrength, time - lastKick > 0.06 {
                fireBeat(intensity: 0.6 + 0.3 * strength, sharpness: 0.8, duration: 0.045)
            }
        }

        // 4. Vibrate.
        let intensity = output * settings.strength
        haptics.setContinuous(intensity: intensity, sharpness: sharpness)

        window.soundDb = max(window.soundDb, db)
        window.bassDb = max(window.bassDb, bassDb)
        window.gateOpen = window.gateOpen || audible
        window.vibration = max(window.vibration, intensity)
    }

    private func fireBeat(intensity: Float, sharpness: Float, duration: Float) {
        let scaled = intensity * settings.strength
        haptics.burst(intensity: scaled, sharpness: sharpness, duration: TimeInterval(duration))
        burstLevel = scaled
        burstUntil = time + duration
        pendingBeats += 1
    }

    private func smooth(toward target: Float, attack: Float, release: Float, dt: Float) {
        let tau = target > output ? attack : release
        output += (target - output) * min(1, dt / tau)
    }
}

/// Remembers the recent quietest and loudest levels and places each new sound between them,
/// so a quiet conversation and a loud concert both use the full range of vibration.
private struct AdaptiveRange {
    var floor: Float = -70
    var ceiling: Float = -30

    /// Returns where `db` sits in the recent range, 0...1.
    mutating func update(_ db: Float, dt: Float) -> Float {
        // Floor drops quickly to new quiet, then creeps up slowly.
        if db < floor {
            floor += (db - floor) * min(1, dt / 0.3)
        } else {
            floor += min(db - floor, 1.0 * dt)
        }
        // Ceiling jumps quickly to new loud, then sags slowly.
        if db > ceiling {
            ceiling += (db - ceiling) * min(1, dt / 0.05)
        } else {
            ceiling -= 2.0 * dt
        }
        ceiling = max(ceiling, floor + 24)
        return min(1, max(0, (db - floor) / (ceiling - floor)))
    }
}

/// Spots a sudden jump in a band's energy: a fast envelope rising well above a slow one.
private struct OnsetDetector {
    let threshold: Float
    let refractory: Float
    private var fast: Float = 0
    private var slow: Float = 0
    private var lastOnset: Float = -1

    init(threshold: Float, refractory: Float) {
        self.threshold = threshold
        self.refractory = refractory
    }

    /// Returns the beat's strength (0.5...1) if one just happened.
    mutating func update(energy: Float, time: Float, dt: Float) -> Float? {
        let amplitude = energy.squareRoot()
        fast += (amplitude - fast) * min(1, dt / 0.01)
        let ratio = fast / (slow + 1e-6)
        slow += (amplitude - slow) * min(1, dt / 0.25)

        guard ratio > threshold, time - lastOnset > refractory else { return nil }
        lastOnset = time
        return min(1, 0.5 + (ratio - threshold) / 4)
    }
}

private struct EnergyMean {
    private var sum = SliceEnergy.zero
    private var count: Float = 0

    mutating func add(_ slice: SliceEnergy) {
        sum.total += slice.total
        sum.low += slice.low
        sum.high += slice.high
        count += 1
    }

    var mean: SliceEnergy {
        guard count > 0 else { return .zero }
        return SliceEnergy(total: sum.total / count, low: sum.low / count, high: sum.high / count, duration: 0)
    }
}

private func decibels(_ power: Float) -> Float {
    10 * log10(max(power, 1e-12))
}
