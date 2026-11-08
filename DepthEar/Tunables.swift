import Combine
import Foundation

enum RateCurve: String, CaseIterable, Identifiable, Codable {
    case linear
    case logarithmic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .logarithmic: return "Logarithmic"
        }
    }
}

/// Timbre of the distance cue.
enum CueSound: String, CaseIterable, Identifiable, Codable {
    /// Rounded tone with a breath of noise: gentle, slightly less precise to locate.
    case soft
    /// Broadband click: harsh, but the sharpest direction cues.
    case click

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .soft: return "Soft tone"
        case .click: return "Sharp click"
        }
    }
}

/// Usable LiDAR range. Samples outside it are discarded, and the click-rate
/// endpoints are defined at these two distances.
enum DepthRange {
    static let nearMeters: Float = 0.5
    static let farMeters: Float = 5.0
}

/// Every runtime-adjustable parameter. Plain value type so the depth and audio
/// queues can take a consistent snapshot through `Locked`.
struct TunableValues: Codable, Equatable {
    /// Forward-prediction horizon for head orientation (the `dt` constant).
    var latencyMs: Double = 150
    /// Click rate at DepthRange.nearMeters.
    var nearRateHz: Double = 6
    /// Click rate at DepthRange.farMeters.
    var farRateHz: Double = 0.7
    var curve: RateCurve = .logarithmic
    /// Median filter length, in processed (30 Hz) depth frames.
    var filterWindow: Int = 5
    /// Head yaw and pitch within ±deadband of the recentered pose snap to zero.
    var deadbandDeg: Double = 2
    var coneAzimuthHalfDeg: Double = 60
    var coneElevationHalfDeg: Double = 15
    /// Selects the alternative CoreMotion headphone axis convention; see README.
    var flipHeadphoneHorizontalAxes: Bool = false
    var cueSound: CueSound = .soft
    /// Linear gain applied to the cue, 0…1.
    var cueVolume: Double = 0.35
    /// No sound for targets farther than this. 5 = always sound.
    var silentBeyondMeters: Double = 3
    /// Show the camera with the target marker while running.
    var showCamera: Bool = true
    /// Standing still: speak the mapped place the head points towards.
    var announcePlaces: Bool = true
    /// Walking: speak the nearest place on the left and right.
    var announceSides: Bool = true
    var announceStreet: Bool = true
    /// Spoken "where am I" summary interval; 0 = off.
    var summaryMinutes: Double = 5
    /// AVSpeechSynthesisVoice identifier; empty = best installed voice.
    var voiceIdentifier: String = ""
    /// AVSpeechUtterance rate, 0…1; 0.5 is the system default.
    var speechRate: Double = 0.5
}

extension TunableValues {
    /// Missing keys take their default, so adding a setting no longer resets
    /// the user's saved values.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TunableValues()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        latencyMs = value(.latencyMs, d.latencyMs)
        nearRateHz = value(.nearRateHz, d.nearRateHz)
        farRateHz = value(.farRateHz, d.farRateHz)
        curve = value(.curve, d.curve)
        filterWindow = value(.filterWindow, d.filterWindow)
        deadbandDeg = value(.deadbandDeg, d.deadbandDeg)
        coneAzimuthHalfDeg = value(.coneAzimuthHalfDeg, d.coneAzimuthHalfDeg)
        coneElevationHalfDeg = value(.coneElevationHalfDeg, d.coneElevationHalfDeg)
        flipHeadphoneHorizontalAxes = value(.flipHeadphoneHorizontalAxes, d.flipHeadphoneHorizontalAxes)
        cueSound = value(.cueSound, d.cueSound)
        cueVolume = value(.cueVolume, d.cueVolume)
        silentBeyondMeters = value(.silentBeyondMeters, d.silentBeyondMeters)
        showCamera = value(.showCamera, d.showCamera)
        announcePlaces = value(.announcePlaces, d.announcePlaces)
        announceSides = value(.announceSides, d.announceSides)
        announceStreet = value(.announceStreet, d.announceStreet)
        summaryMinutes = value(.summaryMinutes, d.summaryMinutes)
        voiceIdentifier = value(.voiceIdentifier, d.voiceIdentifier)
        speechRate = value(.speechRate, d.speechRate)
    }
}

@MainActor
final class Tunables: ObservableObject {
    private static let defaultsKey = "tunables.v4"

    @Published var values: TunableValues {
        didSet {
            shared.set(values)
            if let data = try? JSONEncoder().encode(values) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    /// Lock-protected copy read off the main thread.
    nonisolated let shared: Locked<TunableValues>

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(TunableValues.self, from: $0) }
        let initial = stored ?? TunableValues()
        shared = Locked(initial)
        values = initial
    }

    func resetToDefaults() {
        values = TunableValues()
    }
}
