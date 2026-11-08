import Foundation
import MultipeerConnectivity

/// Finds nearby iPhones running EarLink and keeps a direct, encrypted
/// peer-to-peer session with them (Bluetooth / peer-to-peer Wi-Fi, no internet).
final class PeerLink: NSObject, ObservableObject {
    @Published private(set) var nearby: [MCPeerID] = []
    @Published private(set) var connected: [MCPeerID] = []
    @Published private(set) var connecting: [MCPeerID] = []
    @Published private(set) var displayName: String

    var onData: ((Data, MCPeerID) -> Void)?
    var onDisconnect: ((MCPeerID) -> Void)?

    private static let serviceType = "earlink-talk"

    /// Random token used to decide which side sends the invitation,
    /// so two phones don't invite each other at the same time.
    private let token = UUID().uuidString
    private var peerTokens: [MCPeerID: String] = [:]

    private var myPeer: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!

    init(name: String) {
        displayName = name
        super.init()
        configure(name: name)
    }

    private func configure(name: String) {
        myPeer = MCPeerID(displayName: String(name.prefix(40)))
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        advertiser = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: ["t": token], serviceType: Self.serviceType)
        advertiser.delegate = self
        browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: Self.serviceType)
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayName else { return }
        stop()
        nearby = []
        connected = []
        connecting = []
        peerTokens = [:]
        displayName = trimmed
        configure(name: trimmed)
        start()
    }

    func invite(_ peer: MCPeerID) {
        guard !connected.contains(peer), !connecting.contains(peer) else { return }
        connecting.append(peer)
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }

    func disconnectAll() {
        session.disconnect()
    }

    /// Safe to call from the audio thread.
    func send(_ data: Data) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        try? session.send(data, toPeers: peers, with: .unreliable)
    }

    private func shouldAutoInvite(_ peer: MCPeerID) -> Bool {
        guard let theirs = peerTokens[peer] else { return false }
        return token < theirs
    }
}

extension PeerLink: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard browser === self.browser else { return }
            self.peerTokens[peerID] = info?["t"]
            if !self.nearby.contains(peerID) { self.nearby.append(peerID) }
            if self.shouldAutoInvite(peerID) { self.invite(peerID) }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.nearby.removeAll { $0 == peerID }
        }
    }
}

extension PeerLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension PeerLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard session === self.session else { return }
            self.connecting.removeAll { $0 == peerID }
            self.connected.removeAll { $0 == peerID }
            switch state {
            case .connected:
                self.connected.append(peerID)
            case .connecting:
                self.connecting.append(peerID)
            case .notConnected:
                self.onDisconnect?(peerID)
                // Try to get back together if they're still in range.
                if self.nearby.contains(peerID) && self.shouldAutoInvite(peerID) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.invite(peerID) }
                }
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        onData?(data, peerID)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
