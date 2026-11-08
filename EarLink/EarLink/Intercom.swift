import AVFoundation
import MultipeerConnectivity
import QuartzCore

/// Captures the earbud microphone, sends it to peers, and plays what peers send
/// back into the earbuds. Runs in voice-chat mode, so it never places a phone call.
final class Intercom: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var isTransmitting = false
    @Published private(set) var inputRoute = "—"
    @Published private(set) var outputRoute = "—"
    @Published private(set) var earbudsConnected = false
    @Published var errorMessage: String?

    @Published var micMuted = false { didSet { updateTxEnabled() } }
    @Published var pushToTalk = false { didSet { updateTxEnabled() } }
    @Published var pttPressed = false { didSet { updateTxEnabled() } }
    /// RMS level the voice must exceed before audio is sent (saves Bluetooth bandwidth).
    @Published var noiseGate: Float = 0.008 { didSet { gateThreshold = noiseGate } }

    /// Encoded audio ready to send. Called on the audio thread.
    var onPacket: ((Data) -> Void)?

    private static let wireFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                  channels: 1, interleaved: false)!
    /// Drop incoming audio if this many packets are already queued, to keep latency low.
    private static let maxQueued = 6
    private static let hangover: CFTimeInterval = 0.5

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    // Plain copies of UI state that the audio thread reads.
    private var txEnabled = false
    private var gateThreshold: Float = 0.008
    private var lastVoiceTime: CFTimeInterval = 0
    private var lastLevelUpdate: CFTimeInterval = 0

    private final class Player {
        let node = AVAudioPlayerNode()
        var queued = 0
    }
    private let playerQueue = DispatchQueue(label: "earlink.players")
    private var players: [MCPeerID: Player] = [:]
    private var engineLive = false

    init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(engineConfigChanged), name: .AVAudioEngineConfigurationChange, object: engine)
        updateRoutes()
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    self.startEngine()
                } else {
                    self.errorMessage = "Microphone access is off. Turn it on in Settings › EarLink."
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        stopEngine()
        isRunning = false
        updateTxEnabled()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Hands-free profile (HFP) is what lets us use the earbud mic.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            preferEarbudMic(session)

            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
                throw NSError(domain: "EarLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone available."])
            }
            converter = AVAudioConverter(from: inFormat, to: Self.wireFormat)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 512, format: inFormat) { [weak self] buffer, _ in
                self?.capture(buffer)
            }
            _ = engine.mainMixerNode
            engine.prepare()
            try engine.start()
            playerQueue.sync { engineLive = true }
            isRunning = true
            errorMessage = nil
            updateTxEnabled()
            updateRoutes()
        } catch {
            stopEngine()
            errorMessage = "Couldn't start audio: \(error.localizedDescription)"
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        playerQueue.sync {
            engineLive = false
            for player in players.values { detach(player) }
            players.removeAll()
        }
        isTransmitting = false
        inputLevel = 0
    }

    private func restart() {
        guard isRunning else { return }
        stopEngine()
        isRunning = false
        startEngine()
    }

    private func updateTxEnabled() {
        txEnabled = isRunning && !micMuted && (!pushToTalk || pttPressed)
    }

    private func preferEarbudMic(_ session: AVAudioSession) {
        if let earbuds = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? session.setPreferredInput(earbuds)
        }
    }

    // MARK: - Sending

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.wireFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.wireFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }

        let count = Int(out.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()

        let now = CACurrentMediaTime()
        if rms > gateThreshold { lastVoiceTime = now }
        let sending = txEnabled && now - lastVoiceTime < Self.hangover

        if now - lastLevelUpdate > 0.05 {
            lastLevelUpdate = now
            DispatchQueue.main.async {
                self.inputLevel = rms
                self.isTransmitting = sending
            }
        }

        if sending {
            onPacket?(MuLaw.encode(samples, count: count))
        }
    }

    // MARK: - Receiving

    /// Safe to call from any thread.
    func play(_ data: Data, from peer: MCPeerID) {
        guard !data.isEmpty else { return }
        playerQueue.async { [self] in
            guard engineLive else { return }
            let player = players[peer] ?? makePlayer(for: peer)
            guard player.queued < Self.maxQueued else { return }

            let count = data.count
            guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.wireFormat, frameCapacity: AVAudioFrameCount(count)),
                  let samples = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            let table = MuLaw.decodeTable
            data.withUnsafeBytes { raw in
                for i in 0..<count { samples[i] = table[Int(raw[i])] }
            }

            player.queued += 1
            player.node.scheduleBuffer(buffer) { [weak self] in
                self?.playerQueue.async { player.queued -= 1 }
            }
            if !player.node.isPlaying { player.node.play() }
        }
    }

    func removePeer(_ peer: MCPeerID) {
        playerQueue.async { [self] in
            if let player = players.removeValue(forKey: peer) { detach(player) }
        }
    }

    private func makePlayer(for peer: MCPeerID) -> Player {
        let player = Player()
        engine.attach(player.node)
        engine.connect(player.node, to: engine.mainMixerNode, format: Self.wireFormat)
        players[peer] = player
        return player
    }

    private func detach(_ player: Player) {
        player.node.stop()
        engine.detach(player.node)
    }

    // MARK: - Notifications

    @objc private func routeChanged() {
        DispatchQueue.main.async {
            self.updateRoutes()
            if self.isRunning { self.preferEarbudMic(AVAudioSession.sharedInstance()) }
        }
    }

    @objc private func engineConfigChanged() {
        // Fires when earbuds connect/disconnect; the input format may have changed.
        DispatchQueue.main.async { self.restart() }
    }

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .ended { self.restart() }
        }
    }

    private func updateRoutes() {
        let route = AVAudioSession.sharedInstance().currentRoute
        inputRoute = route.inputs.first?.portName ?? "—"
        outputRoute = route.outputs.first?.portName ?? "—"
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
        earbudsConnected = route.outputs.contains { bluetooth.contains($0.portType) }
    }
}
