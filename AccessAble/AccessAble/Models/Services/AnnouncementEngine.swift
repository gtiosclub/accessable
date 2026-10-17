import AVFoundation
import Foundation
import UIKit

/// Uses VoiceOver's announcement queue while VoiceOver is active; otherwise uses app speech.
actor AnnouncementEngine: AnnouncementEngineProtocol {
    private let delivered = Broadcaster<AnnouncementEvent>()
    private var output: AnnouncementOutput?
    private var profile: GuidanceProfile = .default
    private var isPaused = false
    private var last: AnnouncementEvent?

    func submit(_ event: AnnouncementEvent) async {
        guard !isPaused, profile.allows(event), !event.isExpired() else { return }
        last = event
        delivered.send(event)
        await renderer().deliver(event.text, speechEnabled: profile.channels.contains(.speech), rate: profile.speechRate)
    }

    nonisolated func deliveredEvents() -> AsyncStream<AnnouncementEvent> {
        delivered.stream(bufferingPolicy: .bufferingNewest(8))
    }

    func repeatLast() async {
        guard let last, !isPaused else { return }
        await renderer().deliver(last.text, speechEnabled: profile.channels.contains(.speech), rate: profile.speechRate)
    }

    func pause() async { isPaused = true; await renderer().pause() }
    func resume() async { isPaused = false; await renderer().resume() }
    func updateProfile(_ profile: GuidanceProfile) async { self.profile = profile }

    private func renderer() async -> AnnouncementOutput {
        if let output { return output }
        let created = await MainActor.run { AnnouncementOutput() }
        output = created
        return created
    }
}

@MainActor
private final class AnnouncementOutput {
    private let synthesizer = AVSpeechSynthesizer()

    func deliver(_ text: String, speechEnabled: Bool, rate: Float) {
        guard !text.isEmpty else { return }
        if UIAccessibility.isVoiceOverRunning {
            // Do not overlap VoiceOver with AVSpeechSynthesizer.
            UIAccessibility.post(notification: .announcement, argument: text)
        } else if speechEnabled {
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
            synthesizer.speak(utterance)
        }
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func resume() { synthesizer.continueSpeaking() }
}
