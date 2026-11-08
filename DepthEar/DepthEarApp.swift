import SwiftUI

@main
struct DepthEarApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.tunables)
                .environmentObject(model.places)
        }
        .onChange(of: scenePhase) { _, phase in
            // ARKit stops in the background; clicking at a stale target would
            // be worse than silence.
            switch phase {
            case .background: model.enteredBackground()
            case .active: model.becameActive()
            default: break
            }
        }
    }
}
