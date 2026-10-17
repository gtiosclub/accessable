import AVFoundation
import Observation
import Speech

/// Captures one user-started dictation and publishes the partial/final transcript.
/// Recognition is required to stay on-device when supported; the service fails clearly otherwise.
@MainActor
@Observable
final class SpeechDictation {
    private(set) var isRecording = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var wasCancelled = false
    /// Partial and final transcripts. `isFinal` is true once Speech has finished the utterance.
    @ObservationIgnored var onTranscript: ((String, _ isFinal: Bool) -> Void)?
    /// Called with a message that's safe to read aloud whenever dictation fails.
    @ObservationIgnored var onError: ((String) -> Void)?

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil
        wasCancelled = false

        guard await requestSpeechPermission() else {
            return fail("Allow speech recognition in Settings to dictate commands.")
        }
        guard await requestMicrophonePermission() else {
            return fail("Allow microphone access in Settings to dictate commands.")
        }
        guard let recognizer, recognizer.isAvailable else {
            return fail("Speech recognition is unavailable right now. Try again shortly.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return fail("On-device dictation isn't available for this language on this device.")
        }

        task?.cancel()
        task = nil
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true
        recognitionRequest.addsPunctuation = true
        request = recognitionRequest

        do {
            // Session first: while it's still .playback (SpeechOutput) the input node reports a 0-channel format,
            // and installTap raises an Objective-C exception on that, which crashes the app
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                stopAudioCapture()
                request = nil
                return fail("No microphone is available for dictation.")
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(appendingTo: recognitionRequest))

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            task = recognizer.recognitionTask(
                with: recognitionRequest,
                resultHandler: Self.makeResultHandler { [weak self] transcript, isFinal, didFail in
                    self?.handleResult(transcript: transcript, isFinal: isFinal, didFail: didFail)
                }
            )
        } catch {
            stopAudioCapture()
            request = nil
            fail("Couldn't start dictation. Check microphone access and try again.")
        }
    }

    /// Stops capturing audio; Speech finalizes the transcript and delivers its final result.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        stopAudioCapture()
        request?.endAudio()
        task?.finish()
    }

    func cancel() {
        wasCancelled = true
        isRecording = false
        stopAudioCapture()
        request?.endAudio()
        task?.cancel()
        finishRecognition()
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handleResult(transcript: String?, isFinal: Bool, didFail: Bool) {
        if let transcript { onTranscript?(transcript, isFinal) }
        if isFinal { finishRecognition() }
        if didFail {
            // Also covers stop() with nothing heard; cancel() is the only silent failure
            stop()
            if !wasCancelled, !isFinal { fail("I couldn't hear a command. Please try again.") }
            finishRecognition()
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        onError?(message)
    }

    private func finishRecognition() {
        request = nil
        task = nil
    }

    // MARK: - Callbacks from other threads
    // Speech and AVFAudio call these on their own queues. Under Swift 6, a closure written inside this
    // @MainActor class is main-actor isolated and traps the moment it's called off the main thread,
    // so each one is created in a nonisolated function instead.

    @concurrent
    private nonisolated func requestSpeechPermission() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    @concurrent
    private nonisolated func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    /// Runs on the audio render thread.
    private nonisolated static func makeTap(
        appendingTo request: SFSpeechAudioBufferRecognitionRequest
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    /// Runs on Speech's queue; pulls out Sendable values and hops to the main actor.
    private nonisolated static func makeResultHandler(
        _ handle: @escaping @MainActor @Sendable (_ transcript: String?, _ isFinal: Bool, _ didFail: Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let didFail = error != nil
            Task { @MainActor in handle(transcript, isFinal, didFail) }
        }
    }
}
