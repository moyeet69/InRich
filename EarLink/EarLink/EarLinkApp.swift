import SwiftUI

@main
struct EarLinkApp: App {
    @StateObject private var link: PeerLink
    @StateObject private var intercom = Intercom()

    init() {
        let defaults = UserDefaults.standard
        let name = defaults.string(forKey: "displayName") ?? "EarLink \(Int.random(in: 100...999))"
        defaults.set(name, forKey: "displayName")
        _link = StateObject(wrappedValue: PeerLink(name: name))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(link: link, intercom: intercom)
                .onAppear(perform: wire)
        }
    }

    private func wire() {
        intercom.onPacket = { [weak link] data in link?.send(data) }
        link.onData = { [weak intercom] data, peer in intercom?.play(data, from: peer) }
        link.onDisconnect = { [weak intercom] peer in intercom?.removePeer(peer) }
        link.start()
    }
}
