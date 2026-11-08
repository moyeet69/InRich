import SwiftUI
import MultipeerConnectivity

struct ContentView: View {
    @ObservedObject var link: PeerLink
    @ObservedObject var intercom: Intercom
    @State private var nameDraft = ""
    @FocusState private var editingName: Bool

    var body: some View {
        NavigationStack {
            List {
                statusSection
                peersSection
                settingsSection
                tipsSection
            }
            .navigationTitle("EarLink")
            .safeAreaInset(edge: .bottom) { controls }
            .onAppear { nameDraft = link.displayName }
            .alert("EarLink", isPresented: Binding(
                get: { intercom.errorMessage != nil },
                set: { if !$0 { intercom.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(intercom.errorMessage ?? "")
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            LabeledContent("Mic", value: intercom.inputRoute)
            LabeledContent("Hearing in", value: intercom.outputRoute)
            if !intercom.earbudsConnected {
                Label("Connect your earbuds in Bluetooth settings", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if intercom.isRunning {
                HStack {
                    Image(systemName: intercom.isTransmitting ? "waveform" : "mic")
                        .foregroundStyle(intercom.isTransmitting ? .green : .secondary)
                    LevelMeter(level: intercom.inputLevel, threshold: intercom.noiseGate)
                }
            }
        } header: {
            Text("Audio")
        }
    }

    private var peersSection: some View {
        Section {
            if link.nearby.isEmpty && link.connected.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for nearby iPhones running EarLink…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(allPeers, id: \.self) { peer in
                HStack {
                    Image(systemName: "iphone")
                    Text(peer.displayName)
                    Spacer()
                    peerStatus(peer)
                }
            }
        } header: {
            Text("People")
        } footer: {
            Text("Phones connect automatically when they're nearby. Up to 7 friends can join one conversation.")
        }
    }

    @ViewBuilder
    private func peerStatus(_ peer: MCPeerID) -> some View {
        if link.connected.contains(peer) {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
                .font(.subheadline)
        } else if link.connecting.contains(peer) {
            ProgressView()
        } else {
            Button("Connect") { link.invite(peer) }
                .buttonStyle(.bordered)
        }
    }

    private var allPeers: [MCPeerID] {
        link.connected + link.nearby.filter { !link.connected.contains($0) }
    }

    private var settingsSection: some View {
        Section("Settings") {
            HStack {
                Text("Your name")
                TextField("Name", text: $nameDraft)
                    .multilineTextAlignment(.trailing)
                    .focused($editingName)
                    .submitLabel(.done)
                    .onSubmit(saveName)
            }
            Toggle("Push to talk", isOn: $intercom.pushToTalk)
            VStack(alignment: .leading) {
                Text("Noise gate")
                Slider(value: $intercom.noiseGate, in: 0.001...0.05) {
                    Text("Noise gate")
                } minimumValueLabel: {
                    Image(systemName: "speaker.wave.1")
                } maximumValueLabel: {
                    Image(systemName: "speaker.slash")
                }
                Text("Raise it if background noise keeps your mic open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tipsSection: some View {
        Section("Tips") {
            Label("Turn on Noise Cancellation: open Control Center, long-press the volume slider, then pick Noise Cancellation.",
                  systemImage: "earbuds")
            Label("No calls, SIM, or internet needed. Leave Wi-Fi switched on (no network required) for better range and sound. Bluetooth alone works, but over a shorter range.",
                  systemImage: "antenna.radiowaves.left.and.right")
            Label("Keeps working with the screen locked.", systemImage: "lock")
        }
        .font(.footnote)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            if intercom.isRunning && intercom.pushToTalk {
                pushToTalkButton
            }
            HStack(spacing: 12) {
                Button {
                    intercom.isRunning ? intercom.stop() : intercom.start()
                } label: {
                    Label(intercom.isRunning ? "End" : "Go Live",
                          systemImage: intercom.isRunning ? "stop.fill" : "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(intercom.isRunning ? .red : .accentColor)

                if intercom.isRunning {
                    Button {
                        intercom.micMuted.toggle()
                    } label: {
                        Label(intercom.micMuted ? "Unmute" : "Mute",
                              systemImage: intercom.micMuted ? "mic.slash.fill" : "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(intercom.micMuted ? .orange : .primary)
                }
            }
            .controlSize(.large)
        }
        .padding()
        .background(.bar)
    }

    private var pushToTalkButton: some View {
        Text(intercom.pttPressed ? "Talking…" : "Hold to talk")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(intercom.pttPressed ? Color.green : Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
            .scaleEffect(intercom.pttPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: intercom.pttPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !intercom.pttPressed { intercom.pttPressed = true } }
                    .onEnded { _ in intercom.pttPressed = false }
            )
            .accessibilityAddTraits(.isButton)
    }

    private func saveName() {
        link.rename(nameDraft)
        nameDraft = link.displayName
        UserDefaults.standard.set(link.displayName, forKey: "displayName")
    }
}

private struct LevelMeter: View {
    let level: Float
    let threshold: Float

    var body: some View {
        GeometryReader { geo in
            let scale = { (v: Float) in CGFloat(min(1, v / 0.1)) * geo.size.width }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > threshold ? Color.green : Color.gray)
                    .frame(width: scale(level))
                Rectangle().fill(.orange)
                    .frame(width: 2)
                    .offset(x: scale(threshold))
            }
        }
        .frame(height: 8)
    }
}
