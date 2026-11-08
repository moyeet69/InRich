import SwiftUI

/// One click per touch-down, through the same PHASE spatial path and Bluetooth
/// link as the sonification. See README, "Measuring your latency".
struct LatencyTestView: View {
    @EnvironmentObject private var model: AppModel
    @State private var touching = false
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Record with a second device whose microphone is beside the AirPods and the iPhone screen. Tap the area below sharply with a fingernail or a pen tip, about once a second. Measure each tap-to-click gap in the recording.")
                .fixedSize(horizontal: false, vertical: true)

            Text(String(format: "System-reported output latency: %.0f ms. This is often wrong for Bluetooth, so measure it.", model.reportedOutputLatencyMs))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)

            Text("Taps: \(taps)")
                .monospacedDigit()
                .accessibilityLabel("Taps played")
                .accessibilityValue("\(taps)")

            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(lineWidth: 3)
                .overlay(Text(model.isLatencyTestRunning ? "Tap here" : "Starting audio…").font(.title.bold()))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            // Fire on touch-down only, as early as SwiftUI reports it.
                            guard !touching else { return }
                            touching = true
                            model.playTestClick()
                            taps += 1
                        }
                        .onEnded { _ in touching = false }
                )
                .accessibilityElement()
                .accessibilityLabel("Click pad")
                .accessibilityHint("Direct touch area. Each touch plays one click.")
                .accessibilityAddTraits(.allowsDirectInteraction)
        }
        .padding()
        .navigationTitle("Latency test")
        .onAppear { model.startLatencyTest() }
        .onDisappear { model.stopLatencyTest() }
    }
}
