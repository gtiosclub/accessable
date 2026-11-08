import AVFoundation
import UIKit
 
@MainActor
final class SpeechOutput: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var waiting: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    private var voiceOverWaiter: (text: String, continuation: CheckedContinuation<Void, Never>)?
    private var announcementObserver: NSObjectProtocol?
    /// The best voice installed for the user's language: Premium or Enhanced when they have
    /// downloaded one (Settings → Accessibility → Spoken Content → Voices), far clearer than
    /// the compact default. Listing voices takes a moment, so it is looked up off the main
    /// thread; until then the default voice speaks.
    private var voice: AVSpeechSynthesisVoice?
 
    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        Task { [weak self] in
            let best = await Task.detached(priority: .utility) { Self.bestVoice() }.value
            self?.voice = best
        }
        announcementObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main
        ) { [weak self] note in
            let text = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
            MainActor.assumeIsolated { self?.voiceOverFinished(text) }
        }
    }
 
    isolated deinit {
        if let announcementObserver { NotificationCenter.default.removeObserver(announcementObserver) }
    }
 
    // Speaks text and returns when finished, interrupted, or stop()
    // interrupting: cut off whatever is currently speaking for critical events
    func speak(_ text: String, rate: Float, interrupting: Bool) async {
        if UIAccessibility.isVoiceOverRunning, UIApplication.shared.applicationState == .active {
            await announceWithVoiceOver(text, interrupting: interrupting)
        } else {
            await speakWithSynthesizer(text, rate: rate, interrupting: interrupting)
        }
    }
 
    // Workaround because VoiceOver announcements can't be cancelled
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        voiceOverFinished(voiceOverWaiter?.text)
    }
 
    // AVSpeechSynthesizer stuff
    
    private func speakWithSynthesizer(_ text: String, rate: Float, interrupting: Bool) async {
        if interrupting, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // Set every time: dictation switches the shared session to .record, which would make speech silent
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate // GuidanceProfile.speechRate is already in AVSpeechUtterance units
        await withCheckedContinuation { continuation in
            waiting[ObjectIdentifier(utterance)] = continuation
            synthesizer.speak(utterance)
        }
    }
 
    /// Highest quality for the current language, else for any variant of it ("en-GB" when
    /// only British English is installed), else the system default.
    nonisolated private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let base = language.split(separator: "-").first.map(String.init) ?? language
        // Novelty voices ("Bells", "Albert") are default quality; skip them, and only pick a
        // voice ourselves when it is better than the system's default.
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && $0.quality != .default }
        let exact = voices.filter { $0.language == language }
        let family = voices.filter { $0.language.hasPrefix(base + "-") }
        return (exact.isEmpty ? family : exact).max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        waiting.removeValue(forKey: id)?.resume()
        if waiting.isEmpty, !synthesizer.isSpeaking {
            // De-active
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
 
    // VoiceOver stuff
 
    private func announceWithVoiceOver(_ text: String, interrupting: Bool) async {
        voiceOverFinished(voiceOverWaiter?.text) // never leave an older waiter hanging
        let announcement = NSAttributedString(string: text, attributes: [
            .accessibilitySpeechAnnouncementPriority: interrupting ? UIAccessibilityPriority.high : .default,
            // Queue behind what VoiceOver is currently reading rather than cutting them off
            .accessibilitySpeechQueueAnnouncement: !interrupting,
        ])
        // VoiceOver can drop announcements, so put bounds on waiting
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2 + Double(text.count) / 12))
            self?.voiceOverFinished(text)
        }
        await withCheckedContinuation { continuation in
            voiceOverWaiter = (text, continuation)
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
        timeout.cancel()
    }
 
    private func voiceOverFinished(_ text: String?) {
        guard let waiter = voiceOverWaiter, waiter.text == text else { return }
        voiceOverWaiter = nil
        waiter.continuation.resume()
    }
}
 
extension SpeechOutput: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }
 
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }
}
