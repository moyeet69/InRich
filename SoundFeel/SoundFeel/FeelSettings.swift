import Foundation

enum FeelMode: String, CaseIterable, Identifiable {
    case everySound
    case music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everySound: "Every sound"
        case .music: "Music"
        }
    }

    var detail: String {
        switch self {
        case .everySound:
            "A buzz that follows how loud any sound is. Speech buzzes with each syllable and goes still in pauses."
        case .music:
            "A rumble that follows the bass, plus a strong buzz on every beat. Kicks get a longer buzz; snares and hi-hats a shorter one."
        }
    }
}

struct FeelSettings: Equatable {
    var mode: FeelMode = .everySound
    /// Overall vibration strength, 0...1.
    var strength: Float = 1
    /// Sounds quieter than this (dBFS) are ignored, so background hum doesn't buzz.
    var quietThresholdDb: Float = -55
    /// Subtract the motor's own hum (learned at Start) from what the mic hears.
    var ignoreOwnBuzz = true
}
