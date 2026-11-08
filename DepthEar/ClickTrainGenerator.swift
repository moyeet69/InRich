import Foundation

/// Sample-accurate pulse train. Not thread-safe: use from one queue.
///
/// Two waveforms, chosen with `sound`:
///
/// - Click: a 3 ms burst of frozen white noise with a 0.4 ms exponential
///   decay, first-differenced. Differencing removes DC and tilts the spectrum
///   up ~6 dB/octave, putting most energy in the 2–16 kHz band where
///   interaural level differences and pinna (elevation) cues live. The sharp
///   onset gives a clean interaural time difference.
/// - Soft: a low 330 Hz tone (E4) with one faint overtone, a 15 ms rounded
///   attack and a 90 ms bell-like fade, plus a faint low-passed puff of noise
///   at the onset. No treble and no sharp edge, so it is gentle to hear for a
///   long time; the puff keeps a little high-frequency cue for direction,
///   much less than the click.
///
/// Pulses can overlap at high rates (the soft pulse outlasts a 15 Hz period),
/// so each trigger starts a new voice instead of cutting the previous tail.
/// Every pulse is the same waveform, so timbre carries no spurious information.
final class ClickTrainGenerator {
    private static let maxVoices = 4

    let sampleRate: Double
    let click: [Float]
    let softPulse: [Float]

    var sound: CueSound = .soft

    /// Linear output gain. Ramped across each rendered buffer.
    var gain: Float = 1

    /// Pulses per second; 0 = silent. Changes take effect on the next sample,
    /// scaling the remaining interval instead of waiting it out.
    var rateHz: Double = 0 {
        didSet {
            // Pulse immediately when a target appears rather than after a full
            // (up to 1 s) period.
            if oldValue <= 0, rateHz > 0 { phase = 1 }
        }
    }

    private struct Voice {
        var soft: Bool
        var position: Int
    }

    private var phase: Double = 0
    private var voices: [Voice] = []
    private var currentGain: Float = 1

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        click = Self.makeClick(sampleRate: sampleRate)
        softPulse = Self.makeSoftPulse(sampleRate: sampleRate)
        voices.reserveCapacity(Self.maxVoices)
    }

    func render(into output: UnsafeMutablePointer<Float>, frameCount: Int) {
        let increment = rateHz / sampleRate
        let gainStep = (gain - currentGain) / Float(max(1, frameCount))
        click.withUnsafeBufferPointer { clickWave in
            softPulse.withUnsafeBufferPointer { softWave in
                for i in 0..<frameCount {
                    if increment > 0 {
                        phase += increment
                        if phase >= 1 {
                            phase -= floor(phase)
                            if voices.count == Self.maxVoices { voices.removeFirst() }
                            voices.append(Voice(soft: sound == .soft, position: 0))
                        }
                    }
                    var sample: Float = 0
                    var v = 0
                    while v < voices.count {
                        let wave = voices[v].soft ? softWave : clickWave
                        let position = voices[v].position
                        if position < wave.count {
                            sample += wave[position]
                            voices[v].position = position + 1
                            v += 1
                        } else {
                            voices.remove(at: v)
                        }
                    }
                    currentGain += gainStep
                    output[i] = sample * currentGain
                }
            }
        }
        currentGain = gain
    }

    static func makeClick(sampleRate: Double, peak: Float = 0.8) -> [Float] {
        let length = Int(0.003 * sampleRate)
        let decay = 0.0004 * sampleRate
        var seed: UInt32 = 0x9E37_79B9
        var noise = [Float](repeating: 0, count: length + 1)
        for i in 0...length {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Float(seed >> 8) / Float(1 << 24) * 2 - 1
            noise[i] = white * Float(exp(-Double(i) / decay))
        }
        var click = (0..<length).map { noise[$0 + 1] - noise[$0] }
        normalize(&click, peak: peak)
        return click
    }

    static func makeSoftPulse(sampleRate: Double, peak: Float = 0.18) -> [Float] {
        let length = Int(0.35 * sampleRate)
        let attack = 0.015 * sampleRate
        let release = 0.030 * sampleRate
        let toneDecay = 0.090 * sampleRate
        let noiseDecay = 0.010 * sampleRate
        let w = 2 * Double.pi * 330 / sampleRate
        // One-pole low-pass at ~2.5 kHz: a soft "puff" for direction, no hiss.
        let lowpass = Float(exp(-2 * Double.pi * 2500 / sampleRate))

        var seed: UInt32 = 0x2545_F491
        var filtered: Float = 0
        var pulse = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let t = Double(i)
            var envelope = 1.0
            if t < attack { envelope = 0.5 - 0.5 * cos(Double.pi * t / attack) }
            let remaining = Double(length - i)
            if remaining < release { envelope *= 0.5 - 0.5 * cos(Double.pi * remaining / release) }

            let tone = sin(w * t) + 0.12 * sin(2 * w * t)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Float(seed >> 8) / Float(1 << 24) * 2 - 1
            filtered = lowpass * filtered + (1 - lowpass) * white
            let breath = Double(filtered) * 4 * exp(-t / noiseDecay)

            pulse[i] = Float(envelope * (tone * exp(-t / toneDecay) + 0.08 * breath))
        }
        normalize(&pulse, peak: peak)
        return pulse
    }

    private static func normalize(_ samples: inout [Float], peak: Float) {
        let maxAmplitude = samples.map(abs).max() ?? 1
        guard maxAmplitude > 0 else { return }
        for i in samples.indices { samples[i] *= peak / maxAmplitude }
    }
}
