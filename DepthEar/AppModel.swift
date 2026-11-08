import ARKit
import CoreLocation
import CoreMotion
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var readout: Readout?
    @Published private(set) var startError: String?
    @Published private(set) var isLatencyTestRunning = false

    @Published private(set) var isDescribingLocation = false

    let tunables = Tunables()
    let places = PlaceGuide()
    private let controller: SpatialController
    private let speech: SpeechAnnouncer
    private var lastHeadReceiving: Bool?
    private var placeTimer: Timer?

    var arSession: ARSession { controller.arSession }
    var overlayTarget: Locked<SIMD3<Float>?> { controller.overlayTarget }

    init() {
        controller = SpatialController(tunables: tunables.shared)
        speech = SpeechAnnouncer(tunables: tunables.shared)
        controller.onReadout = { [weak self] readout in
            MainActor.assumeIsolated { self?.apply(readout) }
        }
        speech.onSpeakingChanged = { [weak self] speaking in
            self?.controller.setDucked(speaking)
        }
        places.onCallout = { [weak self] text, kind in
            self?.speech.speak(text, priority: kind == .important ? .urgent : .normal)
        }
        // Lets speech play before Start without the silent switch muting it.
        AudioSessionConfig.setCategory()
    }

    /// Foreground: location runs whenever the app is visible, so "Where am I"
    /// works before Start.
    func becameActive() {
        places.start()
        // Readouts drive the guide while running; this keeps street, side and
        // summary callouts going before Start too.
        placeTimer?.invalidate()
        placeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRunning else { return }
                self.updatePlaces(nil)
            }
        }
    }

    func enteredBackground() {
        stop()
        stopLatencyTest()
        places.stop()
        placeTimer?.invalidate()
        placeTimer = nil
        speech.stopSpeaking()
    }

    // MARK: Actions

    func toggleRunning() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning, !isStarting else { return }
        if isLatencyTestRunning { stopLatencyTest() }
        isStarting = true
        startError = nil
        controller.start { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isStarting = false
                if let error {
                    self.startError = "Could not start audio: \(error.localizedDescription)"
                    self.announce(self.startError ?? "")
                    return
                }
                self.isRunning = true
                self.lastHeadReceiving = nil
                UIApplication.shared.isIdleTimerDisabled = true
                self.announce("Started. Face forward with your head level; recentering automatically.")
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        controller.stop()
        isRunning = false
        readout = nil
        UIApplication.shared.isIdleTimerDisabled = false
        announce("Stopped.")
    }

    func recenter() {
        guard isRunning else {
            announce("Not running. Start first.")
            return
        }
        controller.recenter { [weak self] message in
            MainActor.assumeIsolated { self?.announce(message) }
        }
    }

    func testVoice() {
        speech.test()
    }

    func whereAmI() {
        guard !isDescribingLocation else { return }
        isDescribingLocation = true
        Task {
            let text = await places.whereAmI(headBearing: isRunning ? readout?.headBearingDeg : nil)
            isDescribingLocation = false
            speech.speak(text, priority: .urgent)
        }
    }

    func startLatencyTest() {
        guard !isRunning, !isLatencyTestRunning else { return }
        controller.startLatencyTest { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.announce("Could not start audio: \(error.localizedDescription)")
                } else {
                    self.isLatencyTestRunning = true
                }
            }
        }
    }

    func stopLatencyTest() {
        guard isLatencyTestRunning else { return }
        controller.stopLatencyTest()
        isLatencyTestRunning = false
    }

    func playTestClick() {
        guard isLatencyTestRunning else { return }
        controller.playTestClick()
    }

    var reportedOutputLatencyMs: Double {
        AudioSessionConfig.reportedOutputLatency() * 1000
    }

    // MARK: Warnings

    /// Plain-language problems, most important first. Shown as text, never as
    /// colour alone.
    var warnings: [String] {
        var result: [String] = []
        if let startError { result.append(startError) }
        guard isRunning, let r = readout else { return result }

        if let message = r.pipelineMessage { result.append(message) }
        if !r.head.supported {
            result.append("This iPhone does not support headphone motion. The listener follows the phone, not your head.")
        } else if r.head.authorization == .denied || r.head.authorization == .restricted {
            result.append("Motion & Fitness access is off. Enable it in Settings, Privacy & Security, Motion & Fitness, DepthEar. The listener follows the phone, not your head.")
        } else if !r.head.receiving {
            if r.head.silentSinceStart || r.head.connected == false {
                result.append("No head-tracking data. Use AirPods with head tracking (AirPods Pro, AirPods 3rd generation or later, AirPods Max), in your ears, selected as the audio output. Check that NSMotionUsageDescription is present in Info.plist. The listener follows the phone, not your head.")
            } else {
                result.append("Head-tracking data stopped arriving. The listener follows the phone, not your head.")
            }
        }
        if let error = r.head.error { result.append("Head tracking error: \(error)") }
        if !r.output.isBluetooth {
            result.append("Audio output is \(r.output.name), not AirPods. Select AirPods in Control Center, in the audio output menu.")
        } else if r.output.isHandsFree {
            result.append("AirPods are in hands-free call mode. Binaural quality is reduced. End any call or voice app using the microphone.")
        }
        if r.output.systemSpatialAudioEnabled {
            result.append("System Spatial Audio is available on this output. In Control Center, long-press the volume control, choose Spatial Audio, and set it to Off for DepthEar, to avoid spatializing twice.")
        }
        if r.depthSource == .featurePoints {
            result.append("No LiDAR on this iPhone. Distances come from sparse visual feature points and blank walls may not be detected at all.")
        }
        if let problem = r.trackingProblem { result.append(problem) }
        if tunables.values.announcePlaces || tunables.values.announceSides || tunables.values.announceStreet || tunables.values.summaryMinutes > 0 {
            switch places.authorization {
            case .denied, .restricted:
                result.append("Location access is off, so places cannot be announced. Enable it in Settings, Privacy & Security, Location Services, DepthEar.")
            default:
                if !places.preciseLocation {
                    result.append("Precise Location is off. Place callouts need it. Turn on Precise Location in Settings, Privacy & Security, Location Services, DepthEar.")
                } else if let accuracy = places.location?.horizontalAccuracy, accuracy > 30 {
                    result.append(String(format: "Location is approximate, about %.0f metres. Place directions may be wrong.", accuracy))
                }
            }
            if let error = places.searchError { result.append(error) }
        }
        if r.depthStale { result.append("No current depth data. Audio is silent.") }
        return result
    }

    // MARK: Private

    private func apply(_ readout: Readout) {
        guard isRunning else { return }
        self.readout = readout
        let receiving = readout.head.receiving
        if let last = lastHeadReceiving, last != receiving {
            announce(receiving ? "Head tracking active." : "Head tracking lost. Following the phone.")
        }
        lastHeadReceiving = receiving
        updatePlaces(readout)
    }

    private func updatePlaces(_ readout: Readout?) {
        let v = tunables.values
        places.update(headBearing: readout?.headBearingDeg, bodyBearing: readout?.phoneBearingDeg,
                      settings: GuideSettings(headCallouts: v.announcePlaces, sideCallouts: v.announceSides,
                                              streetCallouts: v.announceStreet, summaryInterval: v.summaryMinutes * 60))
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
