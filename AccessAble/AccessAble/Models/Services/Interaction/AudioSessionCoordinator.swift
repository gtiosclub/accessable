import AVFoundation

/// Owner: User Interaction (3.3). The one place that sets the shared AVAudioSession, so
/// speech, steering tones, push-to-talk dictation and the voice agent's always-on
/// microphone don't undo each other's settings.
///
/// - While the agent listens, the session stays `.playAndRecord` and is never deactivated;
///   speech and tones play through it instead of switching to `.playback`, which would cut
///   the microphone off.
/// - Push-to-talk dictation (`SpeechDictation`) takes the microphone over: the agent stops
///   listening until it ends.
/// - While the app is speaking, the agent ignores the microphone so it doesn't hear itself.
@MainActor
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    /// True while the voice agent holds the microphone open.
    private(set) var keepsMicrophoneOpen = false
    private(set) var isDictating = false
    private var speakingCount = 0

    var isSpeaking: Bool { speakingCount > 0 }

    /// The agent's listener: called when the app starts or stops speaking.
    var onSpeakingChange: ((Bool) -> Void)?
    /// The voice agent: called when push-to-talk dictation starts or ends.
    var onDictationChange: ((Bool) -> Void)?

    private init() {}

    // MARK: - Playback (SpeechOutput, SteeringTones)

    func activateForPlayback() {
        let session = AVAudioSession.sharedInstance()
        if keepsMicrophoneOpen {
            setListeningCategory(on: session)
        } else {
            try? session.setCategory(
                .playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
        }
        try? session.setActive(true)
    }

    /// Lets other apps' audio come back once speech is done, unless the microphone is in use.
    func deactivateAfterPlayback() {
        guard !keepsMicrophoneOpen, !isDictating else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func speechStarted() {
        speakingCount += 1
        if speakingCount == 1 { onSpeakingChange?(true) }
    }

    func speechEnded() {
        guard speakingCount > 0 else { return }
        speakingCount -= 1
        if speakingCount == 0 { onSpeakingChange?(false) }
    }

    // MARK: - Always-on listening (ContinuousSpeechListener)

    func beginListening() throws {
        let session = AVAudioSession.sharedInstance()
        setListeningCategory(on: session)
        try session.setActive(true)
        keepsMicrophoneOpen = true
    }

    func endListening() {
        guard keepsMicrophoneOpen else { return }
        keepsMicrophoneOpen = false
        guard !isDictating, !isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Push-to-talk (SpeechDictation)

    /// Call before dictation configures the session. The agent stops listening synchronously.
    func dictationWillStart() {
        guard !isDictating else { return }
        isDictating = true
        onDictationChange?(true)
    }

    func dictationDidEnd() {
        guard isDictating else { return }
        isDictating = false
        onDictationChange?(false)
    }

    /// Mixes with other audio rather than ducking it: the microphone is open for long
    /// stretches, and ducking the user's music the whole time would be unbearable. Output
    /// goes to the speaker (not the earpiece) or to Bluetooth headphones over A2DP, which keeps
    /// their sound quality; input then comes from the phone's microphone.
    private func setListeningCategory(on session: AVAudioSession) {
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
        guard session.category != .playAndRecord || session.categoryOptions != options else { return }
        try? session.setCategory(.playAndRecord, mode: .default, options: options)
    }
}
