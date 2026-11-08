import AVFoundation
import UIKit

/// SpeechOutput backed by AVSpeechSynthesizer, through the app's own audio
/// session so it mixes with the spatial cue. Reports when it starts and stops
/// so the cue can be ducked under speech rather than replaced by it.
///
/// Use from the main thread.
final class SpeechAnnouncer: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate {
    /// Called on the main queue with true when speech starts, false when it ends.
    var onSpeakingChanged: ((Bool) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let tunables: Locked<TunableValues>
    /// Whether the utterance now playing (or queued last) must not be cut off.
    private var protectedSpeech = false

    init(tunables: Locked<TunableValues>) {
        self.tunables = tunables
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, priority: SpeechPriority) {
        switch priority {
        case .background:
            // Never talk over something already being said.
            guard !synthesizer.isSpeaking else { return }
        case .normal:
            // The latest callout replaces a stale one at a word boundary, but
            // queues behind urgent speech such as a summary.
            if synthesizer.isSpeaking, !protectedSpeech { synthesizer.stopSpeaking(at: .word) }
        case .urgent:
            // Queue behind other urgent speech; cut off anything else.
            if synthesizer.isSpeaking, !protectedSpeech { synthesizer.stopSpeaking(at: .immediate) }
        }
        protectedSpeech = priority == .urgent || (protectedSpeech && synthesizer.isSpeaking)
        synthesizer.speak(makeUtterance(text))
    }

    func stopSpeaking() {
        protectedSpeech = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Speaks a sample sentence with the current settings.
    func test() {
        speak("This is how DepthEar will sound. Coffee shop on your left, about 20 metres.", priority: .urgent)
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let values = tunables.get()
        let utterance = AVSpeechUtterance(string: text)
        let chosen = values.voiceIdentifier.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: values.voiceIdentifier)
        if chosen == nil, UIAccessibility.isVoiceOverRunning {
            // Automatic + VoiceOver: use the VoiceOver voice and rate.
            utterance.prefersAssistiveTechnologySettings = true
        } else {
            utterance.voice = chosen ?? Self.bestVoice()
            utterance.rate = Float(values.speechRate)
        }
        return utterance
    }

    // MARK: Voices

    /// Installed voices for the device language, best quality first. Novelty
    /// voices (Bells, Zarvox…) are left out.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                // Exact region match (en-US vs en-GB) next, then by name.
                if ($0.language == language) != ($1.language == language) { return $0.language == language }
                return $0.name < $1.name
            }
    }

    /// Premium, then Enhanced, then default quality.
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        availableVoices().first ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    static func displayName(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium: quality = "Premium"
        case .enhanced: quality = "Enhanced"
        default: quality = "Basic"
        }
        return "\(voice.name) (\(quality), \(voice.language))"
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        report(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        report(synthesizer.isSpeaking)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        report(synthesizer.isSpeaking)
    }

    private func report(_ speaking: Bool) {
        if !speaking { protectedSpeech = false }
        DispatchQueue.main.async { self.onSpeakingChanged?(speaking) }
    }
}
