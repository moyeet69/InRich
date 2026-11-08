import SwiftUI

struct ContentView: View {
    @StateObject private var engine = SoundFeelEngine()
    @AppStorage("mode") private var mode = FeelMode.everySound
    @AppStorage("strength") private var strength = 1.0
    @AppStorage("quietThreshold") private var quietThreshold = -55.0
    @AppStorage("theaterMode") private var theaterMode = false
    @AppStorage("ignoreOwnBuzz") private var ignoreOwnBuzz = true
    @Environment(\.scenePhase) private var scenePhase

    private var settings: FeelSettings {
        FeelSettings(mode: mode, strength: Float(strength), quietThresholdDb: Float(quietThreshold),
                     ignoreOwnBuzz: ignoreOwnBuzz)
    }

    private var showTheater: Binding<Bool> {
        Binding(
            get: { theaterMode && engine.isActive },
            set: { if !$0 { theaterMode = false } }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PulseView(level: engine.level, beatCount: engine.beatCount, color: .accentColor)
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                    statusLine
                    Button(action: toggle) {
                        Text(engine.isActive ? "Stop" : "Start")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(engine.isActive ? .red : .accentColor)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                }

                meterSection

                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(FeelMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(mode.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Mode")
                }

                Section {
                    VStack(alignment: .leading) {
                        LabeledContent("Strength", value: "\(Int(strength * 100))%")
                        Slider(value: $strength, in: 0.2...1)
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Quiet threshold", value: "\(Int(quietThreshold)) dB")
                        Slider(value: $quietThreshold, in: -80...(-30), step: 1)
                    }
                    Toggle("Ignore the phone's own buzz", isOn: $ignoreOwnBuzz)
                } header: {
                    Text("Feel")
                } footer: {
                    Text("Sounds quieter than the threshold are ignored, so background hum doesn't buzz. Raise it in a noisy room. If loud sound shows on the mic but barely vibrates, try turning off \"Ignore the phone's own buzz\".")
                }

                Section {
                    Toggle("Theater mode", isOn: $theaterMode)
                } footer: {
                    Text("While listening, the screen goes black and dim so it doesn't light up the room. Double-tap to leave.")
                }

                Section {
                    Text("You feel the rhythm and energy of sound, not the melody or the words.")
                    Text("Keep the app open on screen. iOS stops vibration when the phone locks or you switch apps.")
                    Text("At each Start the phone buzzes once to learn its own hum, so it doesn't react to itself.")
                } header: {
                    Text("Good to know")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("SoundFeel")
        }
        .fullScreenCover(isPresented: showTheater) {
            TheaterView(engine: engine) { theaterMode = false }
        }
        .onChange(of: settings) { _, newValue in engine.update(newValue) }
        .onChange(of: engine.isActive) { _, active in
            UIApplication.shared.isIdleTimerDisabled = active
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, engine.isActive { engine.stop() }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch engine.status {
        case .idle:
            Text("Tap Start, then make some noise.").foregroundStyle(.secondary)
        case .calibrating:
            Label("Calibrating…", systemImage: "waveform.badge.magnifyingglass")
        case .listening:
            Label("Listening", systemImage: "waveform")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    private func toggle() {
        engine.isActive ? engine.stop() : engine.start(with: settings)
    }

    private var meterSection: some View {
        let m = engine.meter
        let live = engine.isActive
        return Section {
            HStack(alignment: .firstTextBaseline) {
                Text(live ? "\(Int(m.micDb.rounded()))" : "—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("dB mic").foregroundStyle(.secondary)
                Spacer()
                if live {
                    Text(m.gateOpen ? "Above threshold" : "Below threshold")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(m.gateOpen ? .green : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                LevelBar(value: dbFraction(m.soundDb),
                         marker: dbFraction(Float(quietThreshold)),
                         band: dbFraction(m.floorDb)...dbFraction(m.ceilingDb),
                         color: m.gateOpen ? .green : .gray)
                HStack {
                    Text("−90 dB")
                    Spacer()
                    Text("Red line = quiet threshold")
                    Spacer()
                    Text("0 dB")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Vibration", value: "\(Int(m.vibration * 100))%")
                LevelBar(value: Double(m.vibration), color: .accentColor)
            }

            if mode == .music {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Bass", value: live ? "\(Int(m.bassDb.rounded())) dB" : "—")
                    LevelBar(value: dbFraction(m.bassDb), color: .purple)
                }
            }

            LabeledContent("Microphone") {
                Text(micStatus(m))
                    .foregroundStyle(live && m.slicesPerSecond < 1 ? .red : .secondary)
            }
            LabeledContent("Input", value: live ? engine.inputDescription : "—")
            LabeledContent("Level after removing own buzz",
                           value: live && engine.status == .listening ? "\(Int(m.soundDb.rounded())) dB" : "—")
            LabeledContent("Motor hum (learned at Start)",
                           value: m.humDb.map { "\(Int($0.rounded())) dB" } ?? "—")
            if let error = m.hapticError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button("Set threshold just above this room") {
                quietThreshold = min(-30, max(-80, (Double(m.soundDb) + 6).rounded()))
            }
            .disabled(engine.status != .listening)
            Button("Test buzz", action: engine.testBuzz)
        } header: {
            Text("Meter")
        } footer: {
            Text("Levels are relative to the mic's maximum, so 0 dB is the loudest it can hear. Sound must cross the red line to vibrate. If you feel nothing on Test buzz, check Settings › Sounds & Haptics › System Haptics.")
        }
    }

    private func micStatus(_ m: FeelProcessor.Meter) -> String {
        guard engine.isActive else { return "Off" }
        if m.slicesPerSecond < 1 { return "No audio" }
        let rate = "\(Int(m.slicesPerSecond)) slices/s"
        return engine.usingSlowMic ? "\(rate) (slow mode)" : rate
    }

    private func dbFraction(_ db: Float) -> Double {
        min(1, max(0, Double(db + 90) / 90))
    }
}

/// A horizontal meter with an optional threshold marker and a shaded range.
struct LevelBar: View {
    var value: Double
    var marker: Double? = nil
    var band: ClosedRange<Double>? = nil
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.15))
                if let band {
                    // The room's recent quiet-to-loud range.
                    Rectangle()
                        .fill(color.opacity(0.18))
                        .frame(width: width * (band.upperBound - band.lowerBound))
                        .offset(x: width * band.lowerBound)
                }
                Rectangle()
                    .fill(color)
                    .frame(width: width * value)
                    .animation(.linear(duration: 0.05), value: value)
                if let marker {
                    Rectangle()
                        .fill(.red)
                        .frame(width: 3)
                        .offset(x: width * marker - 1.5)
                }
            }
        }
        .frame(height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// A circle that swells with what you're feeling and flashes a ring on each beat.
struct PulseView: View {
    var level: Float
    var beatCount: Int
    var color: Color
    var faint = false

    @State private var flash = 0.0

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(faint ? 0.12 : 0.3))
                .scaleEffect(0.3 + 0.7 * CGFloat(level))
                .animation(.linear(duration: 0.05), value: level)
            Circle()
                .stroke(color.opacity((faint ? 0.3 : 0.9) * flash), lineWidth: 6)
                .padding(6)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: beatCount) {
            flash = 1
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.25)) { flash = 0 }
            }
        }
    }
}

struct TheaterView: View {
    @ObservedObject var engine: SoundFeelEngine
    var onExit: () -> Void

    @State private var savedBrightness: CGFloat = 0.5
    @State private var showHint = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PulseView(level: engine.level, beatCount: engine.beatCount, color: .white, faint: true)
                .frame(width: 260)
            if showHint {
                VStack {
                    Spacer()
                    Text("Double-tap to leave theater mode")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.bottom, 40)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onExit)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.02
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation { showHint = false }
            }
        }
        .onDisappear { UIScreen.main.brightness = savedBrightness }
    }
}
