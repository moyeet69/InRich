import Foundation

enum RateMapping {
    /// Click repetition rate for a target `distance` metres away.
    ///
    /// - linear: rate is linear in distance between the two endpoints.
    /// - logarithmic: log(rate) is linear in log(distance), i.e. a power law.
    ///   With the default 15 Hz @ 0.5 m and 1 Hz @ 5 m this is rate ∝ d^-1.18,
    ///   close to 1/d, so the gap between clicks grows roughly in proportion to
    ///   distance and most of the rate change happens close in.
    static func rateHz(distance: Float, values: TunableValues) -> Double {
        let dNear = Double(DepthRange.nearMeters)
        let dFar = Double(DepthRange.farMeters)
        let d = min(max(Double(distance), dNear), dFar)
        let near = max(values.nearRateHz, 0.01)
        let far = max(values.farRateHz, 0.01)

        switch values.curve {
        case .linear:
            let t = (d - dNear) / (dFar - dNear)
            return near + (far - near) * t
        case .logarithmic:
            let t = log(d / dNear) / log(dFar / dNear)
            return near * pow(far / near, t)
        }
    }
}
