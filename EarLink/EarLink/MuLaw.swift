import Foundation

/// G.711 µ-law codec. Halves the bandwidth of 16-bit PCM so audio fits
/// comfortably over a Bluetooth-only peer link.
enum MuLaw {
    private static let bias: Int32 = 0x84
    private static let clip: Int32 = 32635

    static func encode(_ samples: UnsafePointer<Float>, count: Int) -> Data {
        var out = Data(count: count)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for i in 0..<count { dst[i] = encodeSample(samples[i]) }
        }
        return out
    }

    static func encodeSample(_ value: Float) -> UInt8 {
        var s = Int32(max(-1, min(1, value)) * 32767)
        let sign: Int32 = s < 0 ? 0x80 : 0
        if s < 0 { s = -s }
        if s > clip { s = clip }
        s += bias
        var exponent: Int32 = 7
        var mask: Int32 = 0x4000
        while exponent > 0 && (s & mask) == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (s >> (exponent + 3)) & 0x0F
        return UInt8(truncatingIfNeeded: ~(sign | (exponent << 4) | mantissa))
    }

    /// Lookup table from µ-law byte to a Float sample in -1...1.
    static let decodeTable: [Float] = (0..<256).map { decodeByte(UInt8($0)) }

    private static func decodeByte(_ byte: UInt8) -> Float {
        let u = Int32(~byte)
        let sign = u & 0x80
        let exponent = (u >> 4) & 0x07
        let mantissa = u & 0x0F
        let s = (((mantissa << 3) + bias) << exponent) - bias
        return Float(sign != 0 ? -s : s) / 32768
    }
}
