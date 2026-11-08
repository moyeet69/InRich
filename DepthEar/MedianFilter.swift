import simd

/// Component-wise running median over the last `window` target positions.
/// Rejects single-frame LiDAR speckle (flying pixels at depth edges) without
/// the smearing a mean filter adds across a genuine step change.
struct MedianFilter3D {
    private var history: [SIMD3<Float>] = []

    var window: Int {
        didSet { trim() }
    }

    init(window: Int) {
        self.window = max(1, window)
    }

    var isEmpty: Bool { history.isEmpty }

    /// Median of the current history. Only valid when `!isEmpty`.
    var current: SIMD3<Float> {
        SIMD3(Self.median(history.map(\.x)),
              Self.median(history.map(\.y)),
              Self.median(history.map(\.z)))
    }

    mutating func push(_ point: SIMD3<Float>) -> SIMD3<Float> {
        history.append(point)
        trim()
        return current
    }

    mutating func reset() {
        history.removeAll(keepingCapacity: true)
    }

    private mutating func trim() {
        let limit = max(1, window)
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : 0.5 * (sorted[n / 2 - 1] + sorted[n / 2])
    }
}
