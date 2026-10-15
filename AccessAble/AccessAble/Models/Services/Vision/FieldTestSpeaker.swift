import AVFoundation
import UIKit

/// Owner: Computer Vision (1.4). Speaks delivered announcements and plays their haptics on
/// the Live detection screen, so CV's warnings can be heard and felt during device testing
/// before the real announcement engine and haptics (3.3, 3.2) land.
///
/// It is a test harness, not the engine: it follows the same contract the engine will —
/// more urgent speech interrupts less urgent speech, at most one announcement waits, and
/// stale ones are dropped — so what testers hear is a fair preview of the timing.
@MainActor
final class FieldTestSpeaker: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var speaking: AnnouncementEvent?
    private var waiting: AnnouncementEvent?

    private let light = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        light.prepare()
        heavy.prepare()
        notification.prepare()
    }

    func deactivate() {
        waiting = nil
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func deliver(_ event: AnnouncementEvent) {
        if let haptic = event.haptic { play(haptic) }

        guard let current = speaking else {
            speak(event)
            return
        }
        if event.priority > current.priority {
            // `didCancel` speaks what is waiting.
            waiting = event
            synthesizer.stopSpeaking(at: .immediate)
        } else if waiting.map({ event.priority >= $0.priority }) ?? true {
            waiting = event
        }
    }

    private func speak(_ event: AnnouncementEvent) {
        speaking = event
        let utterance = AVSpeechUtterance(string: event.text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        synthesizer.speak(utterance)
    }

    private func finishedSpeaking() {
        speaking = nil
        guard let next = waiting else { return }
        waiting = nil
        if !next.isExpired() { speak(next) }
    }

    private func play(_ haptic: HapticID) {
        switch haptic {
        case .stop, .error: notification.notificationOccurred(.error)
        case .obstacleNearer, .attention: heavy.impactOccurred()
        default: light.impactOccurred()
        }
    }
}

extension FieldTestSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }
}
