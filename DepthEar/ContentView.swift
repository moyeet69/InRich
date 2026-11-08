import SwiftUI

struct ContentView: View {
    @AppStorage("safetyAcknowledged.v2") private var acknowledged = false

    var body: some View {
        if acknowledged {
            MainView()
        } else {
            SafetyAcknowledgmentView { acknowledged = true }
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tunables: Tunables
    @State private var showingSafety = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if model.isRunning, tunables.values.showCamera {
                        CameraPanel(readout: model.readout)
                    }

                    Button(action: model.toggleRunning) {
                        Text(model.isRunning ? "Stop" : (model.isStarting ? "Starting…" : "Start"))
                            .font(.title.bold())
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isStarting)
                    .accessibilityLabel(model.isRunning ? "Stop sonification" : "Start sonification")
                    .accessibilityHint(model.isRunning ? "Stops the camera and the clicks." : "Starts depth sensing, head tracking and the clicks.")

                    Button(action: model.recenter) {
                        VStack(spacing: 8) {
                            Text("Recenter")
                                .font(.largeTitle.bold())
                            Text("Face forward, head level, then tap.")
                                .font(.body)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isRunning)
                    .accessibilityLabel("Recenter head tracking")
                    .accessibilityHint("Face straight ahead with your head level, then double-tap. A two-finger double-tap anywhere on the screen also recenters.")

                    Button(action: model.whereAmI) {
                        Text(model.isDescribingLocation ? "Looking up…" : "Where am I?")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isDescribingLocation)
                    .accessibilityLabel("Where am I")
                    .accessibilityHint("Speaks your street, address, the direction you are facing, what is on your left and right, and the nearest mapped place. Directions need Start and head tracking.")

                    WarningsSection(warnings: model.warnings)
                    ReadoutSection(readout: model.readout, isRunning: model.isRunning)
                    PlacesSection(places: model.places, readout: model.readout, isRunning: model.isRunning)

                    NavigationLink {
                        TunablesView()
                    } label: {
                        Text("Tunables").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Sound, volume, place callouts, camera view, latency compensation, click rates, filter window, deadband and cone width.")

                    NavigationLink {
                        LatencyTestView()
                    } label: {
                        Text("Latency test").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRunning)
                    .accessibilityHint("Plays one click per tap, for measuring Bluetooth audio latency. Stop sonification first.")

                    Button {
                        showingSafety = true
                    } label: {
                        Text("Safety statement").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Reads the safety statement again.")
                }
                .padding()
            }
            .navigationTitle("DepthEar")
            .sheet(isPresented: $showingSafety) {
                NavigationStack {
                    ScrollView { SafetyStatementText().padding() }
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSafety = false }
                                    .accessibilityLabel("Close safety statement")
                            }
                        }
                }
            }
        }
        // VoiceOver "magic tap" (two-finger double-tap anywhere): recenter
        // without having to find the button.
        .accessibilityAction(.magicTap) { model.recenter() }
    }
}

/// Camera with the target marker and a small heads-up display. Hidden from
/// VoiceOver: everything it shows is also in the readouts.
private struct CameraPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var places: PlaceGuide
    let readout: Readout?

    var body: some View {
        CameraPreview(session: model.arSession, target: model.overlayTarget)
            .aspectRatio(3 / 4, contentMode: .fit)
            .frame(maxHeight: 420)
            .overlay {
                // Centre of the sensing cone.
                Image(systemName: "plus")
                    .font(.title2.weight(.light))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.distance(readout?.distance))
                        .font(.title3.bold().monospacedDigit())
                    if let rate = readout?.clickRateHz, rate > 0 {
                        Text(String(format: "%.1f pulses/s", rate))
                    }
                    if let bearing = readout?.headBearingDeg {
                        Text(String(format: "Head %.0f° %@", bearing, PlaceGuide.compassName(bearing)))
                    }
                    if let facing = places.facing {
                        Text("→ \(facing.name), \(PlaceGuide.roundedDistance(facing.distance)) m")
                            .lineLimit(1)
                    }
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
    }
}

private struct PlacesSection: View {
    @ObservedObject var places: PlaceGuide
    let readout: Readout?
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Places")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let bearing = isRunning ? readout?.headBearingDeg : nil {
                let source = readout?.usingHeadTracking == true ? "head" : "phone"
                ReadoutRow(label: "Facing (\(source))", value: String(format: "%.0f° %@", bearing, PlaceGuide.compassName(bearing)),
                           spoken: String(format: "%@, %.0f degrees", PlaceGuide.compassName(bearing), bearing))
            } else {
                ReadoutRow(label: "Facing", value: "Start to measure")
            }
            ReadoutRow(label: "Street", value: places.street ?? "Unknown")
            ReadoutRow(label: "Moving", value: places.isWalking ? "Walking" : "Standing still")
            ReadoutRow(label: "Pointing at", value: places.facing.map(PlaceGuide.describe) ?? "No mapped place")
            ReadoutRow(label: "On your left", value: places.left.map(PlaceGuide.describe) ?? "Nothing mapped within 60 m")
            ReadoutRow(label: "On your right", value: places.right.map(PlaceGuide.describe) ?? "Nothing mapped within 60 m")
            ReadoutRow(label: "Mapped places within 300 m", value: "\(places.placeCount)")
            if let accuracy = places.location?.horizontalAccuracy {
                ReadoutRow(label: "Location accuracy", value: String(format: "±%.0f m", accuracy),
                           spoken: String(format: "plus or minus %.0f metres", accuracy))
            } else {
                ReadoutRow(label: "Location", value: "Waiting for a fix")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WarningsSection: View {
    let warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Warnings")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    Label {
                        Text(warning).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Warning: \(warning)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ReadoutSection: View {
    let readout: Readout?
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live readout")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let r = readout, isRunning {
                ReadoutRow(label: "Target distance", value: Format.distance(r.distance), spoken: Format.distanceSpoken(r.distance))
                ReadoutRow(label: "Azimuth, head-relative", value: Format.side(r.azimuthDeg, positive: "right", negative: "left"),
                           spoken: Format.sideSpoken(r.azimuthDeg, positive: "right", negative: "left"))
                ReadoutRow(label: "Elevation, head-relative", value: Format.side(r.elevationDeg, positive: "up", negative: "down"),
                           spoken: Format.sideSpoken(r.elevationDeg, positive: "up", negative: "down"))
                ReadoutRow(label: "Pulse rate", value: r.clickRateHz > 0 ? String(format: "%.1f Hz", r.clickRateHz) : "Silent",
                           spoken: r.clickRateHz > 0 ? String(format: "%.1f hertz", r.clickRateHz) : "Silent")
                ReadoutRow(label: "Depth frame rate", value: String(format: "%.0f Hz", r.depthFPS),
                           spoken: String(format: "%.0f frames per second", r.depthFPS))
                ReadoutRow(label: "Depth source", value: r.depthSource.displayName)
                ReadoutRow(label: "Samples in cone", value: "\(r.samplesInCone)")
                ReadoutRow(label: "Head tracking", value: Format.headTracking(r), spoken: Format.headTracking(r))
                if let angles = r.headAngles {
                    ReadoutRow(label: "Head pose (predicted)", value: Format.headPose(angles), spoken: Format.headPose(angles))
                }
                if let horizon = r.predictionHorizonMs {
                    ReadoutRow(label: "Prediction horizon", value: String(format: "%.0f ms", horizon),
                               spoken: String(format: "%.0f milliseconds", horizon))
                }
                ReadoutRow(label: "Prediction check", value: Format.predictionCheck(r.head.predictionErrorRatio))
                ReadoutRow(label: "Audio output", value: r.output.name + (r.output.isBluetooth ? ", Bluetooth" : ""))
            } else {
                Text("Not running.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReadoutRow: View {
    let label: String
    let value: String
    var spoken: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken ?? value)
    }
}

enum Format {
    static func distance(_ d: Float?) -> String {
        guard let d else { return "None in range" }
        return String(format: "%.2f m", d)
    }

    static func distanceSpoken(_ d: Float?) -> String {
        guard let d else { return "None in range" }
        return String(format: "%.2f meters", d)
    }

    static func side(_ deg: Float?, positive: String, negative: String) -> String {
        guard let deg else { return "None" }
        if abs(deg) < 0.5 { return "0°" }
        return String(format: "%.0f° %@", abs(deg), deg > 0 ? positive : negative)
    }

    static func sideSpoken(_ deg: Float?, positive: String, negative: String) -> String {
        guard let deg else { return "None" }
        if abs(deg) < 0.5 { return "0 degrees" }
        return String(format: "%.0f degrees %@", abs(deg), deg > 0 ? positive : negative)
    }

    static func headTracking(_ r: Readout) -> String {
        guard r.head.receiving else { return "No data arriving" }
        let location = r.head.sensorLocation.map { ", \($0)" } ?? ""
        let mode = r.usingHeadTracking ? "" : ", not yet centered"
        return String(format: "Receiving, %.0f samples per second", r.head.sampleRateHz) + location + mode
    }

    /// HeadAngles uses yaw > 0 = left; spoken as plain directions.
    static func headPose(_ a: HeadAngles) -> String {
        let yaw = degrees(a.yaw), pitch = degrees(a.pitch), roll = degrees(a.roll)
        return "Yaw " + sideSpoken(-yaw, positive: "right", negative: "left")
            + ", pitch " + sideSpoken(pitch, positive: "up", negative: "down")
            + ", roll " + sideSpoken(roll, positive: "left ear down", negative: "right ear down")
    }

    static func predictionCheck(_ ratio: Double?) -> String {
        guard let ratio else { return "Turn your head a few times to measure" }
        let percent = Int((ratio * 100).rounded())
        let verdict = ratio < 1 ? "prediction is helping" : "prediction is making it worse; see README"
        return "Error \(percent)% of no prediction, \(verdict)"
    }
}
