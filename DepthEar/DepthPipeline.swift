import ARKit
import simd

enum DepthSource: Equatable {
    case lidar
    case featurePoints

    var displayName: String {
        switch self {
        case .lidar: return "LiDAR smoothed scene depth"
        case .featurePoints: return "Visual feature points (no LiDAR: sparse and unreliable)"
        }
    }
}

/// The sensing cone, gravity-referenced: azimuth is measured in the horizontal
/// plane from the phone's compass heading, elevation from the horizon. Tilting
/// the phone up or down does not tilt the cone.
struct ConeParameters {
    /// Unit horizontal vector the phone is pointing along (world frame).
    var forward: SIMD3<Float>
    /// Unit horizontal vector to the right of `forward`.
    var right: SIMD3<Float>
    var tanAzimuth: Float
    var tanElevationSquared: Float
    var minRangeSquared: Float
    var maxRangeSquared: Float

    init(forward: SIMD3<Float>, values: TunableValues) {
        self.forward = forward
        right = SIMD3(-forward.z, 0, forward.x)
        tanAzimuth = tan(radians(Float(min(values.coneAzimuthHalfDeg, 89))))
        let tanEl = tan(radians(Float(min(values.coneElevationHalfDeg, 89))))
        tanElevationSquared = tanEl * tanEl
        minRangeSquared = DepthRange.nearMeters * DepthRange.nearMeters
        maxRangeSquared = DepthRange.farMeters * DepthRange.farMeters
    }
}

struct DepthResult {
    var timestamp: TimeInterval
    var cameraPosition: SIMD3<Float>
    /// Phone heading about world +Y (see `headingRotation`); nil when the phone
    /// points too close to straight up or down to define one.
    var heading: Float?
    /// Median-filtered nearest return, world frame. nil = nothing in the cone.
    var target: SIMD3<Float>?
    var samplesInCone: Int
    /// nil when ARKit tracking is normal.
    var trackingProblem: String?
    var framesPerSecond: Double
    var source: DepthSource
}

/// ARKit session plus the per-frame reduction to a single target. All work
/// runs on `queue` (the ARSession delegate queue), never on the main thread.
final class DepthPipeline: NSObject, ARSessionDelegate {
    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    static let processingInterval: TimeInterval = 1.0 / 30.0

    let session = ARSession()
    var onResult: ((DepthResult) -> Void)?
    /// Latest filtered target, world frame, for the camera overlay.
    let overlayTarget = Locked<SIMD3<Float>?>(nil)
    /// Called with a message to show, or nil to clear a previous one.
    var onError: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "depthear.depth", qos: .userInteractive)
    private let tunables: Locked<TunableValues>
    private let source: DepthSource = DepthPipeline.hasLiDAR ? .lidar : .featurePoints

    // Touched only on `queue`.
    private var filter = MedianFilter3D(window: 5)
    private var missedFrames = 0
    private var lastProcessed: TimeInterval = 0
    private var fpsWindowStart: TimeInterval = 0
    private var fpsFrameCount = 0
    private var framesPerSecond: Double = 0
    private var columnTerms: [Float] = []

    init(tunables: Locked<TunableValues>) {
        self.tunables = tunables
        super.init()
    }

    /// Call on the main thread.
    func start() {
        let configuration = ARWorldTrackingConfiguration()
        // -z points to true north and +x to east, so world headings convert
        // directly to compass bearings for the place callouts. Alignment uses
        // the compass at session start and is only as good as the compass.
        configuration.worldAlignment = .gravityAndHeading
        if Self.hasLiDAR {
            configuration.frameSemantics = .smoothedSceneDepth
        }
        queue.async {
            self.filter.reset()
            self.missedFrames = 0
            self.lastProcessed = 0
            self.fpsWindowStart = 0
            self.fpsFrameCount = 0
            self.framesPerSecond = 0
        }
        session.delegateQueue = queue
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Call on the main thread.
    func stop() {
        session.pause()
        overlayTarget.set(nil)
    }

    // MARK: ARSessionDelegate (called on `queue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ARKit delivers 60 Hz; reduce to 30 Hz. The frame is not retained.
        guard frame.timestamp - lastProcessed >= Self.processingInterval * 0.9 else { return }
        lastProcessed = frame.timestamp
        process(frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        if let arError = error as? ARError, arError.code == .cameraUnauthorized {
            onError?("Camera access is denied. Enable it in Settings, Privacy & Security, Camera, DepthEar.")
        } else {
            onError?("AR session failed: \(error.localizedDescription)")
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onError?("AR session interrupted. Depth sensing is paused.")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        onError?(nil)
    }

    // MARK: Per-frame reduction

    private func process(_ frame: ARFrame) {
        let values = tunables.get()
        filter.window = values.filterWindow
        updateFrameRate(frame.timestamp)

        let t = frame.camera.transform
        let position = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let lookDirection = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let horizontalLength = simd_length(SIMD2(lookDirection.x, lookDirection.z))

        var heading: Float?
        var nearest: (offset: SIMD3<Float>, count: Int)?
        // Within ~72° of horizontal; beyond that "forward" is not meaningful.
        if horizontalLength > 0.3 {
            let forward = SIMD3(lookDirection.x / horizontalLength, 0, lookDirection.z / horizontalLength)
            heading = atan2(-forward.x, -forward.z)
            let cone = ConeParameters(forward: forward, values: values)
            // EXTENSION POINT (TargetExtractor): multi-target extraction replaces
            // the two single-nearest reductions below.
            if let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
                nearest = nearestLiDARSample(depth: depth, camera: frame.camera, cone: cone)
            } else if source == .featurePoints {
                nearest = nearestFeaturePoint(frame.rawFeaturePoints, origin: position, cone: cone)
            }
        }

        var target: SIMD3<Float>?
        if let nearest, nearest.count > 0 {
            missedFrames = 0
            target = filter.push(position + nearest.offset)
        } else {
            missedFrames += 1
            // Hold through short dropouts; go silent after a full window of misses.
            if missedFrames >= max(1, values.filterWindow) {
                filter.reset()
            } else if !filter.isEmpty {
                target = filter.current
            }
        }

        overlayTarget.set(target)
        onResult?(DepthResult(
            timestamp: frame.timestamp,
            cameraPosition: position,
            heading: heading,
            target: target,
            samplesInCone: nearest?.count ?? 0,
            trackingProblem: Self.describe(frame.camera.trackingState),
            framesPerSecond: framesPerSecond,
            source: source
        ))
    }

    /// Nearest medium/high-confidence depth sample inside the cone, as an
    /// offset from the camera in world coordinates.
    ///
    /// A depth pixel (u, v) with depth d unprojects to the camera-space point
    /// d·(a_u, -b_v, -1) with a_u = (u - cx)/fx, b_v = (v - cy)/fy (ARKit camera
    /// axes: x right, y up, -z out of the lens). The projections onto the cone's
    /// forward, right and up axes are therefore linear in a_u and b_v, so each
    /// pixel costs a handful of multiply-adds and no trig or square roots.
    private func nearestLiDARSample(depth: ARDepthData, camera: ARCamera, cone: ConeParameters) -> (offset: SIMD3<Float>, count: Int)? {
        let depthMap = depth.depthMap
        guard let confidenceMap = depth.confidenceMap else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0,
              CVPixelBufferGetWidth(confidenceMap) == width,
              CVPixelBufferGetHeight(confidenceMap) == height,
              let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap) else { return nil }
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)

        // Intrinsics are given for the captured image; rescale to the depth map.
        let k = camera.intrinsics
        let sx = Float(width) / Float(camera.imageResolution.width)
        let sy = Float(height) / Float(camera.imageResolution.height)
        let fx = k.columns.0.x * sx, fy = k.columns.1.y * sy
        let cx = k.columns.2.x * sx, cy = k.columns.2.y * sy

        let t = camera.transform
        let camX = SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z)
        let camY = SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z)
        let camZ = SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let up = SIMD3<Float>(0, 1, 0)
        let xF = simd_dot(camX, cone.forward), yF = simd_dot(camY, cone.forward), zF = simd_dot(camZ, cone.forward)
        let xR = simd_dot(camX, cone.right), yR = simd_dot(camY, cone.right), zR = simd_dot(camZ, cone.right)
        let xU = simd_dot(camX, up), yU = simd_dot(camY, up), zU = simd_dot(camZ, up)

        if columnTerms.count != width { columnTerms = [Float](repeating: 0, count: width) }
        for u in 0..<width { columnTerms[u] = (Float(u) + 0.5 - cx) / fx }

        let lowConfidence = UInt8(ARConfidenceLevel.low.rawValue)
        let tanAz = cone.tanAzimuth, tanEl2 = cone.tanElevationSquared
        let minR2 = cone.minRangeSquared, maxR2 = cone.maxRangeSquared

        var bestRange2 = Float.infinity
        var best = SIMD3<Float>(0, 0, 0)
        var count = 0

        columnTerms.withUnsafeBufferPointer { au in
            for v in 0..<height {
                let depthRow = (depthBase + v * depthStride).assumingMemoryBound(to: Float32.self)
                let confidenceRow = (confidenceBase + v * confidenceStride).assumingMemoryBound(to: UInt8.self)
                let bv = (Float(v) + 0.5 - cy) / fy
                let rowF = -bv * yF - zF
                let rowR = -bv * yR - zR
                let rowU = -bv * yU - zU
                for u in 0..<width {
                    if confidenceRow[u] <= lowConfidence { continue }
                    let d = depthRow[u]
                    if !(d > 0) { continue }   // also rejects NaN
                    let a = au[u]
                    let f = d * (a * xF + rowF)
                    if f <= 0 { continue }
                    let r = d * (a * xR + rowR)
                    if abs(r) > tanAz * f { continue }
                    let h = d * (a * xU + rowU)
                    let horizontal2 = f * f + r * r
                    if h * h > tanEl2 * horizontal2 { continue }
                    let range2 = horizontal2 + h * h
                    if range2 < minR2 || range2 > maxR2 { continue }
                    count += 1
                    if range2 < bestRange2 {
                        bestRange2 = range2
                        best = SIMD3(f, r, h)
                    }
                }
            }
        }

        let offset = best.x * cone.forward + best.y * cone.right + best.z * up
        return (offset, count)
    }

    /// Fallback for phones without LiDAR: nearest ARKit feature point in the
    /// cone. Feature points are sparse and absent on blank walls, so this mode
    /// cannot reliably tell a plain wall from an opening.
    private func nearestFeaturePoint(_ cloud: ARPointCloud?, origin: SIMD3<Float>, cone: ConeParameters) -> (offset: SIMD3<Float>, count: Int)? {
        guard let cloud else { return nil }
        var bestRange2 = Float.infinity
        var best = SIMD3<Float>(0, 0, 0)
        var count = 0
        for point in cloud.points {
            let o = point - origin
            let f = simd_dot(o, cone.forward)
            if f <= 0 { continue }
            let r = simd_dot(o, cone.right)
            if abs(r) > cone.tanAzimuth * f { continue }
            let horizontal2 = f * f + r * r
            if o.y * o.y > cone.tanElevationSquared * horizontal2 { continue }
            let range2 = horizontal2 + o.y * o.y
            if range2 < cone.minRangeSquared || range2 > cone.maxRangeSquared { continue }
            count += 1
            if range2 < bestRange2 {
                bestRange2 = range2
                best = o
            }
        }
        return (best, count)
    }

    private func updateFrameRate(_ timestamp: TimeInterval) {
        if fpsWindowStart == 0 { fpsWindowStart = timestamp }
        fpsFrameCount += 1
        let elapsed = timestamp - fpsWindowStart
        if elapsed >= 1 {
            framesPerSecond = Double(fpsFrameCount) / elapsed
            fpsFrameCount = 0
            fpsWindowStart = timestamp
        }
    }

    private static func describe(_ state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal:
            return nil
        case .notAvailable:
            return "Tracking not available"
        case .limited(let reason):
            switch reason {
            case .initializing: return "Tracking initializing. Move the phone slowly."
            case .excessiveMotion: return "Tracking limited: phone moving too fast"
            case .insufficientFeatures: return "Tracking limited: too few visual features (dark or blank surroundings)"
            case .relocalizing: return "Tracking relocalizing"
            @unknown default: return "Tracking limited"
            }
        }
    }
}
