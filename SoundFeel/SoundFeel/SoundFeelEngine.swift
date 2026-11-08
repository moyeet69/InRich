import AVFoundation
import Combine
import UIKit

/// Listen → analyze → decide → vibrate. Owns the mic, the haptics and the processing queue,
/// and publishes a little live state for the UI.
final class SoundFeelEngine: ObservableObject {
    enum Status: Equatable {
        case idle
        case calibrating
        case listening
        case failed(String)
    }

    @Published private(set) var status = Status.idle
    /// What's being felt right now, 0...1.
    @Published private(set) var level: Float = 0
    /// Increments on every beat; the UI flashes when it changes.
    @Published private(set) var beatCount = 0
    @Published private(set) var meter = FeelProcessor.Meter()
    /// True when the mic fell back to the slower standard tap.
    @Published private(set) var usingSlowMic = false
    /// Which microphone is in use and its format.
    @Published private(set) var inputDescription = "—"

    var isActive: Bool { status == .calibrating || status == .listening }

    private let queue = DispatchQueue(label: "SoundFeel.processing", qos: .userInteractive)
    private let listener = AudioListener()
    private let haptics = HapticPlayer()
    /// Only touched on `queue`.
    private var processor: FeelProcessor?
    /// Bumped on every Start so a stale watchdog from an earlier run does nothing.
    private var runID = 0
    private var gotAudio = false
    /// Loudest raw mic level this run; stuck near -120 dB means the mic is sending silence.
    private var loudestMicDb: Float = -120

    init() {
        haptics.onInterrupted = { [weak self] in
            self?.queue.async { self?.haptics.recover() }
        }
    }

    func start(with settings: FeelSettings) {
        guard !isActive else { return }
        guard HapticPlayer.isSupported else {
            status = .failed("This device has no Taptic Engine, so it can't vibrate to sound.")
            return
        }
        status = .calibrating
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    self.begin(with: settings)
                } else {
                    self.status = .failed("Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone.")
                }
            }
        }
    }

    func stop() {
        runID += 1
        listener.onSlice = nil
        listener.stop()
        queue.sync {
            processor = nil
            haptics.stop()
        }
        status = .idle
        level = 0
        meter = FeelProcessor.Meter()
    }

    func update(_ settings: FeelSettings) {
        queue.async { self.processor?.settings = settings }
    }

    /// One strong buzz, to check the motor works at all.
    func testBuzz() {
        if isActive {
            queue.async { self.haptics.burst(intensity: 1, sharpness: 0.5, duration: 0.4) }
        } else {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
        }
    }

    private func begin(with settings: FeelSettings) {
        do {
            try AudioListener.configureSession()
            try queue.sync {
                try haptics.start()
                processor = FeelProcessor(settings: settings, haptics: haptics) { [weak self] snapshot in
                    DispatchQueue.main.async { self?.apply(snapshot) }
                }
            }
            listener.onSlice = { [weak self] slice in
                self?.queue.async { self?.processor?.process(slice) }
            }
            runID += 1
            gotAudio = false
            loudestMicDb = -120
            usingSlowMic = false
            try listener.start()
            inputDescription = listener.inputDescription
            watchForAudio(run: runID)
        } catch {
            stop()
            status = .failed(error.localizedDescription)
        }
    }

    /// If the fast mic path delivers nothing (or only digital silence), retry with a standard
    /// tap; if that fails too, say so.
    private func watchForAudio(run: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.runID == run, self.isActive else { return }
            let micWorks = self.gotAudio && self.loudestMicDb > -110
            guard !micWorks else { return }
            if !self.listener.usingTap {
                do {
                    try self.listener.restart(usingTap: true)
                    self.usingSlowMic = true
                    self.inputDescription = self.listener.inputDescription
                    self.gotAudio = false
                    self.watchForAudio(run: run)
                } catch {
                    self.stop()
                    self.status = .failed("Couldn't restart the microphone: \(error.localizedDescription)")
                }
            } else {
                self.stop()
                self.status = .failed(self.gotAudio
                    ? "The microphone is only sending silence. Check that no other app (calls, voice memos, Siri) is using it, then try again."
                    : "The microphone isn't delivering any sound. Close other apps using the mic, or restart the phone.")
            }
        }
    }

    private func apply(_ snapshot: FeelProcessor.Snapshot) {
        // Ignore snapshots that arrive after Stop.
        guard isActive else { return }
        gotAudio = true
        loudestMicDb = max(loudestMicDb, snapshot.meter.micDb)
        status = snapshot.calibrating ? .calibrating : .listening
        level = snapshot.level
        beatCount += snapshot.beats
        meter = snapshot.meter
    }
}
