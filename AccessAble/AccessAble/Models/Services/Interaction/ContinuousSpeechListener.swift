import AVFoundation
import Speech
import UIKit
import os

private let log = Logger(subsystem: "AccessAble", category: "VoiceAgent")

/// Owner: User Interaction (3.1). Keeps the microphone open and hands over each thing the
/// user says once they pause. Recognition stays on the device.
///
/// One recognition task covers one utterance: after a pause it is finished and a fresh one
/// starts, which also keeps each task well under Speech's per-task time limit. Recognition
/// is held, and anything half-heard is thrown away, while the app is speaking or VoiceOver is
/// reading a control, so the agent doesn't act on its own voice.
@MainActor
final class ContinuousSpeechListener {
    enum StartError: Error {
        case speechDenied
        case microphoneDenied
        case recognizerUnavailable
        case onDeviceUnsupported
        case audioUnavailable

        var spokenMessage: String {
            switch self {
            case .speechDenied: "Allow speech recognition in Settings to use the voice assistant."
            case .microphoneDenied: "Allow microphone access in Settings to use the voice assistant."
            case .recognizerUnavailable: "Speech recognition is unavailable right now."
            case .onDeviceUnsupported: "On-device speech recognition isn't available for this language."
            case .audioUnavailable: "The microphone couldn't be started."
            }
        }
    }

    /// The words so far, while the user is still talking.
    var onPartial: ((String) -> Void)?
    /// Everything said before the pause.
    var onUtterance: ((String) -> Void)?
    /// After an audio interruption (a phone call) the microphone couldn't come back.
    var onStopped: ((StartError) -> Void)?

    private(set) var isRunning = false

    /// How long a pause ends what the user is saying.
    private static let endOfUtterancePause: Duration = .milliseconds(1300)

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let sink = AudioBufferSink()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Bumped whenever a task is dropped, so its late callbacks are ignored.
    private var generation = 0
    private var transcript = ""
    private var taskStartedAt = Date.distantPast
    private var endOfUtterance: Task<Void, Never>?
    private var resume: Task<Void, Never>?
    private var isHeldForSpeech = false
    private var voiceOverHold: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private var isHeld: Bool { isHeldForSpeech || voiceOverHold != nil }

    func start() async throws {
        guard !isRunning else { return }
        guard await Self.requestSpeechPermission() else { throw StartError.speechDenied }
        guard await Self.requestMicrophonePermission() else { throw StartError.microphoneDenied }
        guard let recognizer, recognizer.isAvailable else { throw StartError.recognizerUnavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw StartError.onDeviceUnsupported }
        guard !isRunning else { return } // started again while waiting for permission

        try startAudio()
        isRunning = true
        observeNotifications()
        let coordinator = AudioSessionCoordinator.shared
        coordinator.onSpeakingChange = { [weak self] isSpeaking in self?.speakingChanged(isSpeaking) }
        isHeldForSpeech = coordinator.isSpeaking
        beginRecognition()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        endRecognition()
        resume?.cancel()
        resume = nil
        voiceOverHold?.cancel()
        voiceOverHold = nil
        stopAudio()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        AudioSessionCoordinator.shared.onSpeakingChange = nil
        AudioSessionCoordinator.shared.endListening()
    }

    // MARK: - Audio

    private func startAudio() throws {
        do {
            try AudioSessionCoordinator.shared.beginListening()
        } catch {
            log.error("Listening session failed: \(error.localizedDescription)")
            throw StartError.audioUnavailable
        }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            AudioSessionCoordinator.shared.endListening()
            throw StartError.audioUnavailable
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(sink))
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            AudioSessionCoordinator.shared.endListening()
            log.error("Audio engine failed: \(error.localizedDescription)")
            throw StartError.audioUnavailable
        }
    }

    private func stopAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// After a route change or interruption the engine stops and its tap's format is stale.
    private func restartAudio() {
        guard isRunning else { return }
        endRecognition()
        stopAudio()
        do {
            try startAudio()
            beginRecognition()
        } catch let error as StartError {
            stop()
            onStopped?(error)
        } catch {
            stop()
            onStopped?(.audioUnavailable)
        }
    }

    // MARK: - Recognition

    private func beginRecognition() {
        guard isRunning, !isHeld, task == nil, let recognizer else { return }
        generation += 1
        let generation = generation
        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        self.request = request
        sink.request = request
        taskStartedAt = .now
        task = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeResultHandler { [weak self] transcript, isFinal, didFail in
                self?.handleResult(generation: generation, transcript: transcript, isFinal: isFinal, didFail: didFail)
            }
        )
    }

    private func endRecognition() {
        generation += 1
        endOfUtterance?.cancel()
        endOfUtterance = nil
        sink.request = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        transcript = ""
    }

    private func handleResult(generation: Int, transcript text: String?, isFinal: Bool, didFail: Bool) {
        guard generation == self.generation, isRunning else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            onPartial?(text)
            scheduleEndOfUtterance()
        }
        guard isFinal || didFail else { return }
        if !transcript.isEmpty {
            finishUtterance()
        } else {
            // Silence long enough for Speech to give up: start listening again.
            endRecognition()
            // A recognizer that fails straight away would otherwise spin.
            if didFail, Date.now.timeIntervalSince(taskStartedAt) < 1 {
                resumeRecognition(after: .seconds(1))
            } else {
                beginRecognition()
            }
        }
    }

    private func scheduleEndOfUtterance() {
        endOfUtterance?.cancel()
        endOfUtterance = Task { [weak self] in
            try? await Task.sleep(for: Self.endOfUtterancePause)
            guard !Task.isCancelled else { return }
            self?.finishUtterance()
        }
    }

    private func finishUtterance() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        endRecognition()
        beginRecognition()
        if text.count >= 2 { onUtterance?(text) }
    }

    private func resumeRecognition(after delay: Duration) {
        resume?.cancel()
        resume = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            resume = nil
            beginRecognition()
        }
    }

    // MARK: - Not hearing ourselves

    private func speakingChanged(_ isSpeaking: Bool) {
        guard isRunning else { return }
        if isSpeaking {
            isHeldForSpeech = true
            endRecognition()
        } else {
            isHeldForSpeech = false
            // Let the tail of the speech die away first.
            resumeRecognition(after: .milliseconds(300))
        }
    }

    /// VoiceOver reads each control as the user moves to it; that speech isn't a command.
    private func voiceOverFocusMoved(label: String?) {
        guard isRunning else { return }
        endRecognition()
        voiceOverHold?.cancel()
        let seconds = 1.0 + Double(label?.count ?? 20) / 14
        voiceOverHold = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            voiceOverHold = nil
            beginRecognition()
        }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIAccessibility.elementFocusedNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Delivered on the main queue, where the element may be read.
            nonisolated(unsafe) let element = note.userInfo?[UIAccessibility.focusedElementUserInfoKey] as? NSObject
            MainActor.assumeIsolated {
                guard UIAccessibility.isVoiceOverRunning else { return }
                self?.voiceOverFocusMoved(label: element?.accessibilityLabel)
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                switch type {
                case .began:
                    self.endRecognition()
                case .ended:
                    self.restartAudio()
                @unknown default:
                    break
                }
            }
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAudio() }
        })
    }

    // MARK: - Callbacks from other threads
    // As in SpeechDictation: closures made inside this @MainActor class would trap when Speech
    // or the audio thread calls them, so they are made in nonisolated functions.

    @concurrent
    private nonisolated static func requestSpeechPermission() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    @concurrent
    private nonisolated static func requestMicrophonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    /// Runs on the audio render thread.
    private nonisolated static func makeTap(_ sink: AudioBufferSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer) }
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

/// Hands microphone buffers from the audio thread to whichever recognition request is
/// current. Between requests (and while recognition is held) buffers are dropped.
private final class AudioBufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { current }?.append(buffer)
    }
}
