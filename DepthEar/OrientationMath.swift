import simd

/// Euler angles in ARKit's head-local convention (x right, y up, -z forward),
/// decomposed as R = Ry(yaw) · Rx(pitch) · Rz(roll). Radians.
/// yaw > 0 = turned left, pitch > 0 = looking up, roll > 0 = left ear down.
struct HeadAngles: Equatable {
    var yaw: Float
    var pitch: Float
    var roll: Float

    init(yaw: Float, pitch: Float, roll: Float) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    init(_ q: simd_quatf) {
        // Column-major: m.columns.j[i] is row i, column j.
        let m = simd_float3x3(q)
        pitch = asin(max(-1, min(1, -m.columns.2.y)))
        yaw = atan2(m.columns.2.x, m.columns.2.z)
        roll = atan2(m.columns.0.y, m.columns.1.y)
    }

    var quaternion: simd_quatf {
        simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: roll, axis: SIMD3(0, 0, 1))
    }
}

extension simd_quatd {
    static let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    /// Rotation produced by a constant body-frame angular velocity `rate`
    /// (rad/s) held for `dt` seconds: exp(½·ω·dt).
    static func rotation(rate: SIMD3<Double>, over dt: Double) -> simd_quatd {
        let angle = simd_length(rate) * dt
        guard angle > 1e-9 else { return .identity }
        return simd_quatd(angle: angle, axis: simd_normalize(rate))
    }
}

/// Smallest rotation angle (radians) between two orientations.
func angularDistance(_ a: simd_quatd, _ b: simd_quatd) -> Double {
    let d = min(1, abs(simd_dot(a.vector, b.vector)))
    return 2 * acos(d)
}

/// Rotation about world +Y that turns ARKit forward (0, 0, -1) to `heading`.
func headingRotation(_ heading: Float) -> simd_quatf {
    simd_quatf(angle: heading, axis: SIMD3(0, 1, 0))
}

func degrees<T: BinaryFloatingPoint>(_ radians: T) -> T { radians * 180 / .pi }
func radians<T: BinaryFloatingPoint>(_ degrees: T) -> T { degrees * .pi / 180 }
