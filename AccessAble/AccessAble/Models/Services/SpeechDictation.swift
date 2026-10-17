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
    @ObservationIgnored var onTranscript: ((String) -> Void)?

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil

        guard await requestSpeechPermission() else {
            errorMessage = "Allow speech recognition in Settings to dictate commands."
            return
        }
        guard await requestMicrophonePermission() else {
            errorMessage = "Allow microphone access in Settings to dictate commands."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition is unavailable right now. Try again shortly."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            errorMessage = "On-device dictation isn't available for this language on this device."
            return
        }

        task?.cancel()
        task = nil
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true
        recognitionRequest.addsPunctuation = true
        request = recognitionRequest

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                // Extract Sendable values before hopping back to the main actor.
                let transcript = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let didFail = error != nil
                Task { @MainActor in
                    guard let self else { return }
                    if let transcript { self.onTranscript?(transcript) }
                    if isFinal { self.finishRecognition() }
                    if didFail {
                        if self.isRecording {
                            self.stop()
                            self.errorMessage = "I couldn't transcribe that. Please try again."
                        }
                        self.finishRecognition()
                    }
                }
            }
        } catch {
            stopAudioCapture()
            request = nil
            errorMessage = "Couldn't start dictation. Check microphone access and try again."
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

    private func finishRecognition() {
        request = nil
        task = nil
    }

    private func requestSpeechPermission() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}
