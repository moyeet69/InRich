import AVFoundation
import SwiftUI

struct TunablesView: View {
    @EnvironmentObject private var tunables: Tunables
    @EnvironmentObject private var model: AppModel
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        Form {
            Section {
                Picker("Sound", selection: $tunables.values.cueSound) {
                    ForEach(CueSound.allCases) { sound in
                        Text(sound.displayName).tag(sound)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Sound")
                LabeledSlider(title: "Volume", value: $tunables.values.cueVolume,
                              range: 0.05...1, step: 0.05, unit: "", spokenUnit: "", decimals: 2)
                LabeledSlider(title: "Silent beyond", value: $tunables.values.silentBeyondMeters,
                              range: 1...5, step: 0.25, unit: "m", spokenUnit: "metres", decimals: 2)
            } header: {
                Text("Sound")
            } footer: {
                Text("Soft tone is gentle and rounded. Sharp click is harsher but gives the most precise sense of direction, especially up and down. Nothing plays when the nearest surface is farther than the Silent beyond distance; set it to 5 metres to always hear something. The cue drops to a third of its volume while speech is playing. Pulses are slow by default: 6 per second at half a metre, about 1 per second at 3 metres.")
            }

            Section {
                Picker("Voice", selection: $tunables.values.voiceIdentifier) {
                    Text("Automatic (best installed)").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text(SpeechAnnouncer.displayName(voice)).tag(voice.identifier)
                    }
                }
                LabeledSlider(title: "Speaking speed", value: $tunables.values.speechRate,
                              range: 0.3...0.65, step: 0.025, unit: "", spokenUnit: "", decimals: 2)
                Button("Test voice") { model.testVoice() }
                    .accessibilityHint("Speaks a sample callout with the chosen voice and speed.")
            } header: {
                Text("Voice")
            } footer: {
                Text("For the most natural, Siri-like sound, download a Premium voice. Open Settings, Accessibility, Spoken Content, Voices, choose your language, and download a voice marked Premium or Enhanced, such as Ava, Zoe or Evan. Then come back here; Automatic picks the best one. Apple does not let apps use the Siri voices themselves. With VoiceOver on and Automatic selected, callouts use your VoiceOver voice and speed.")
            }
            .onAppear { voices = SpeechAnnouncer.availableVoices() }

            Section {
                Toggle("Head-turn callouts when standing", isOn: $tunables.values.announcePlaces)
                    .accessibilityHint("When you stop, turn your head and hold still to hear the mapped place in that direction and how far it is.")
                Toggle("Left and right while walking", isOn: $tunables.values.announceSides)
                    .accessibilityHint("While walking, speaks the nearest mapped place on each side, within 60 metres.")
                Toggle("Announce street changes", isOn: $tunables.values.announceStreet)
                Stepper(value: $tunables.values.summaryMinutes, in: 0...30, step: 1) {
                    Text(tunables.values.summaryMinutes == 0 ? "Location summary: off" : "Location summary every \(Int(tunables.values.summaryMinutes)) min")
                }
                .accessibilityLabel("Location summary interval")
                .accessibilityValue(tunables.values.summaryMinutes == 0 ? "Off" : "Every \(Int(tunables.values.summaryMinutes)) minutes")
                Toggle("Show camera view", isOn: $tunables.values.showCamera)
                    .accessibilityHint("Shows the camera with a marker on the detected surface. For sighted helpers.")
            } header: {
                Text("Places and camera")
            } footer: {
                Text("Place callouts use Apple Maps, GPS and the compass. Walking or standing is detected by the motion sensor, with a few seconds' delay. While walking you hear what is on each side; when you stop, turn your head and hold still for under a second to hear what is there. The summary repeats your street, address and surroundings. Directions can be off by many degrees indoors or near steel and electronics; recenter often.")
            }

            Section {
                LabeledSlider(title: "Latency compensation", value: $tunables.values.latencyMs,
                              range: 0...300, step: 5, unit: "ms", spokenUnit: "milliseconds", decimals: 0)
                LabeledSlider(title: "Center deadband", value: $tunables.values.deadbandDeg,
                              range: 0...10, step: 0.5, unit: "°", spokenUnit: "degrees", decimals: 1)
                Toggle("Flip headphone horizontal axes", isOn: $tunables.values.flipHeadphoneHorizontalAxes)
                    .accessibilityHint("Use only if nodding down reads as up in the head pose readout.")
            } header: {
                Text("Head tracking")
            } footer: {
                Text("Latency compensation is the forward-prediction time added to each head-tracking sample's age. Measure it with the Latency test, then fine-tune by ear. Head yaw and pitch within the deadband of center are treated as exactly center.")
            }

            Section {
                LabeledSlider(title: "Rate at 0.5 metres", value: $tunables.values.nearRateHz,
                              range: 1...30, step: 0.5, unit: "Hz", spokenUnit: "hertz", decimals: 1)
                LabeledSlider(title: "Rate at 5 metres", value: $tunables.values.farRateHz,
                              range: 0.2...10, step: 0.1, unit: "Hz", spokenUnit: "hertz", decimals: 1)
                Picker("Rate curve", selection: $tunables.values.curve) {
                    ForEach(RateCurve.allCases) { curve in
                        Text(curve.displayName).tag(curve)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Rate curve")
            } header: {
                Text("Click rate")
            } footer: {
                Text("Linear: rate changes evenly with distance. Logarithmic: a power law, close to rate proportional to one over distance, so most of the change happens close in.")
            }

            Section {
                Stepper(value: $tunables.values.filterWindow, in: 1...15) {
                    Text("Median filter window: \(tunables.values.filterWindow) frames")
                }
                .accessibilityLabel("Median filter window")
                .accessibilityValue("\(tunables.values.filterWindow) frames")
                LabeledSlider(title: "Cone half-width, azimuth", value: $tunables.values.coneAzimuthHalfDeg,
                              range: 5...90, step: 1, unit: "°", spokenUnit: "degrees", decimals: 0)
                LabeledSlider(title: "Cone half-height, elevation", value: $tunables.values.coneElevationHalfDeg,
                              range: 2...45, step: 1, unit: "°", spokenUnit: "degrees", decimals: 0)
            } header: {
                Text("Depth")
            } footer: {
                Text("The camera's field of view limits the cone to about plus or minus 25 to 35 degrees whatever this is set to. A narrow cone makes doorways easier to find.")
            }

            Section {
                Button("Reset all to defaults", role: .destructive) {
                    tunables.resetToDefaults()
                }
                .accessibilityHint("Soft tone at volume 0.35, silent beyond 3 metres, 6 and 0.7 hertz logarithmic, all callouts on, summary every 5 minutes, camera on, latency 150 milliseconds, 5 frames, 2 degrees, cone 60 by 15 degrees.")
            }
        }
        .navigationTitle("Tunables")
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let spokenUnit: String
    let decimals: Int

    private var formatted: String { String(format: "%.\(decimals)f", value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(unit == "°" || unit.isEmpty ? formatted + unit : formatted + " " + unit)
                    .monospacedDigit()
            }
            .accessibilityHidden(true)
            Slider(value: $value, in: range, step: step) {
                Text(title)
            }
            .accessibilityLabel(title)
            .accessibilityValue(spokenUnit.isEmpty ? formatted : "\(formatted) \(spokenUnit)")
            // VoiceOver swipe up/down moves by exactly one step.
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value = min(range.upperBound, value + step)
                case .decrement: value = max(range.lowerBound, value - step)
                @unknown default: break
                }
            }
        }
    }
}
