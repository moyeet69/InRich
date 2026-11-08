import AVFoundation

struct OutputRoute: Equatable {
    var name: String
    var isBluetooth: Bool
    /// Bluetooth hands-free profile: low-bandwidth mono call audio.
    var isHandsFree: Bool
    /// AVAudioSessionPortDescription.isSpatialAudioEnabled: the port supports
    /// system spatial audio and the feature is on. It does NOT say whether the
    /// system is spatializing this app's stream; see README.
    var systemSpatialAudioEnabled: Bool

    static let none = OutputRoute(name: "None", isBluetooth: false, isHandsFree: false, systemSpatialAudioEnabled: false)
}

/// Audio session setup.
///
/// iOS has no AVAudioSession property that disables system spatialization.
/// The only explicit bypass, setIntendedSpatialExperience(.bypassed), is
/// visionOS-only and marked unavailable on iOS in the SDK headers. What this
/// configuration does instead:
///
/// - `.playback` + `.default` mode: full-bandwidth A2DP output. Never
///   `.playAndRecord`: with AirPods that falls back to the hands-free profile.
/// - `.mixWithOthers`: the app never becomes the Now Playing app. The system's
///   per-app Spatial Audio control in Control Center appears to key off Now
///   Playing audio. That is observed behaviour, not documented; see README.
/// - `setSupportsMultichannelContent(false)`: tells the system this is not
///   multichannel content to be rendered spatially (it is also the default).
/// - PHASE renders the binaural signal itself (`outputSpatializationMode =
///   .alwaysUseBinaural`) and, on iOS 18+, its own automatic head tracking is
///   explicitly switched off (see SpatialRenderer).
///
/// The user still has to set Control Center > Spatial Audio to Off while
/// DepthEar is in the foreground, and the UI warns when the route reports
/// system spatial audio as enabled.
enum AudioSessionConfig {
    /// Category only, without activating. Speech can then play before Start.
    static func setCategory() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setSupportsMultichannelContent(false)
        // Smaller IO buffer = less output latency before the Bluetooth link.
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static func currentOutput() -> OutputRoute {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return .none }
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return OutputRoute(
            name: port.portName,
            isBluetooth: bluetooth.contains(port.portType),
            isHandsFree: port.portType == .bluetoothHFP,
            systemSpatialAudioEnabled: port.isSpatialAudioEnabled
        )
    }

    /// The system's own output latency estimate (seconds). Often wrong for
    /// Bluetooth; shown only as a hint next to the measured value.
    static func reportedOutputLatency() -> TimeInterval {
        let session = AVAudioSession.sharedInstance()
        return session.outputLatency + session.ioBufferDuration
    }
}
