import Foundation

/// Mean signal power of one ~5 ms slice of sound, overall and in two bands.
struct SliceEnergy {
    var total: Float
    /// Below ~150 Hz: kick drums, bass guitar.
    var low: Float
    /// Above ~2.5 kHz: snares, claps, hi-hats, consonants.
    var high: Float
    var duration: Float

    static let zero = SliceEnergy(total: 0, low: 0, high: 0, duration: 0)

    /// Subtracts `other * scale` from each band, never going below zero.
    func removing(_ other: SliceEnergy, scale: Float) -> SliceEnergy {
        SliceEnergy(total: max(0, total - other.total * scale),
                    low: max(0, low - other.low * scale),
                    high: max(0, high - other.high * scale),
                    duration: duration)
    }
}

/// Splits microphone samples into ~5 ms slices and measures each one.
///
/// Runs on the real-time audio thread, so it only does arithmetic: no allocation, no locks.
/// Samples are measured and then thrown away; nothing is kept.
final class BandSplitter {
    private let sliceLength: Int
    private let sliceDuration: Float
    private let lowCoef: Float
    private let highCoef: Float
    private let onSlice: (SliceEnergy) -> Void

    // Filter state: two one-pole low-passes for bass, one low-pass subtracted for treble.
    private var low1: Float = 0
    private var low2: Float = 0
    private var trebleBase: Float = 0

    private var sumTotal: Float = 0
    private var sumLow: Float = 0
    private var sumHigh: Float = 0
    private var count = 0

    init(sampleRate: Double, onSlice: @escaping (SliceEnergy) -> Void) {
        sliceLength = max(32, Int(sampleRate * 0.005))
        sliceDuration = Float(Double(sliceLength) / sampleRate)
        lowCoef = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        highCoef = Float(1 - exp(-2 * Double.pi * 2500 / sampleRate))
        self.onSlice = onSlice
    }

    func process(_ samples: UnsafePointer<Float>, count frames: Int) {
        for i in 0..<frames {
            let x = samples[i]
            low1 += lowCoef * (x - low1)
            low2 += lowCoef * (low1 - low2)
            trebleBase += highCoef * (x - trebleBase)
            let treble = x - trebleBase

            sumTotal += x * x
            sumLow += low2 * low2
            sumHigh += treble * treble
            count += 1

            if count == sliceLength {
                let n = Float(sliceLength)
                onSlice(SliceEnergy(total: sumTotal / n, low: sumLow / n, high: sumHigh / n,
                                    duration: sliceDuration))
                sumTotal = 0
                sumLow = 0
                sumHigh = 0
                count = 0
            }
        }
    }
}
