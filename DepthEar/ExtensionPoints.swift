import ARKit
import simd

// Milestone 2+ seams. Nothing here is called by Milestone 1. Each protocol
// names where it attaches; matching `EXTENSION POINT` comments mark the call
// sites in DepthPipeline and SpatialController. See ARCHITECTURE.md.

struct SemanticLabel {
    var name: String
    var confidence: Float
}

struct SpatialTarget {
    var worldPosition: SIMD3<Float>
    var distance: Float
    /// 0…1, used to rank and limit simultaneous sources.
    var salience: Float
    var label: SemanticLabel?
}

struct ListenerPose {
    var position: SIMD3<Float>
    /// ARKit convention: x right, y up, -z forward.
    var orientation: simd_quatf
}

/// Replaces "single nearest sample in the cone" with several targets per
/// frame. Called synchronously on the depth queue at 30 Hz from
/// DepthPipeline.process(_:). It must not retain the frame.
protocol TargetExtractor: AnyObject {
    func targets(in frame: ARFrame, cone: ConeParameters) -> [SpatialTarget]
}

/// Renders several targets, each its own PHASESource with a distinct timbre.
/// Replaces SpatialRenderer, called from SpatialController.tick() at 100 Hz
/// with the same latency-compensated listener pose.
protocol Sonifier: AnyObject {
    func start() throws
    func stop()
    func render(targets: [SpatialTarget], listener: ListenerPose)
}

/// Object classification (ARKit mesh classification, Vision, Core ML).
/// Runs after TargetExtractor, off the 30 Hz path, and attaches labels.
protocol SemanticLabeler: AnyObject {
    func label(_ targets: [SpatialTarget], image: CVPixelBuffer) async -> [SpatialTarget]
}

/// VLM scene description. On demand only, never per frame.
protocol SceneDescriber: AnyObject {
    func describeScene(image: CVPixelBuffer, targets: [SpatialTarget]) async throws -> String
}

enum SpeechPriority {
    case background
    case normal
    case urgent
}

/// Speech output. Must duck the spatial cue, not replace it, and defer to
/// VoiceOver when it is running.
protocol SpeechOutput: AnyObject {
    func speak(_ text: String, priority: SpeechPriority)
    func stopSpeaking()
}

/// Route guidance: supplies a waypoint rendered as a separate, clearly
/// distinct source.
protocol RouteGuide: AnyObject {
    func nextWaypoint(for listener: ListenerPose) -> SpatialTarget?
}

// MARK: - Milestone 1 stubs

final class NoSemanticLabeler: SemanticLabeler {
    func label(_ targets: [SpatialTarget], image: CVPixelBuffer) async -> [SpatialTarget] { targets }
}

final class NoSceneDescriber: SceneDescriber {
    struct NotImplemented: Error {}
    func describeScene(image: CVPixelBuffer, targets: [SpatialTarget]) async throws -> String {
        throw NotImplemented()
    }
}

final class NoSpeechOutput: SpeechOutput {
    func speak(_ text: String, priority: SpeechPriority) {}
    func stopSpeaking() {}
}

final class NoRouteGuide: RouteGuide {
    func nextWaypoint(for listener: ListenerPose) -> SpatialTarget? { nil }
}
