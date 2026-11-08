import AVFoundation
import os

/// Plays the steering beep (`SteeringCue`). Owner: Computer Vision (1.1).
///
/// A short tone placed in 3D, so with headphones it comes from the side to move towards
/// (and stays put as the head turns, with AirPods). On the phone's own speaker it is panned
/// as far as the speakers allow. Beeps repeat at the cue's interval and stop the moment the
/// cue goes away. The engine runs only while there is something to steer around.
@MainActor
final class SteeringTones {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    /// Low, middle and high beeps for far, nearer and close.
    private lazy var beeps: [AVAudioPCMBuffer] = [660, 880, 1_175].compactMap { makeBeep(frequency: $0) }
    private var cue: SteeringCue?
    private var loop: Task<Void, Never>?
    private var isConfigured = false
    private let log = Logger(subsystem: "AccessAble", category: "SteeringTones")

    /// Follows `cue`; nil falls silent.
    func update(_ cue: SteeringCue?) {
        self.cue = cue
        guard cue != nil else {
            loop?.cancel()
            loop = nil
            stopEngine()
            return
        }
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        guard startEngine() else {
            loop = nil
            return
        }
        while !Task.isCancelled, let cue {
            beep(cue)
            try? await Task.sleep(for: .seconds(cue.interval))
        }
    }

    private func beep(_ cue: SteeringCue) {
        // Up to 70 degrees off centre: far enough to the side to be unmistakable, not so far
        // that left and behind blur together.
        let angle = cue.side * 70 * .pi / 180
        player.position = AVAudio3DPoint(x: sin(angle), y: 0, z: -cos(angle))
        player.pan = cue.side
        let pitch = min(Int(cue.urgency * Float(beeps.count)), beeps.count - 1)
        guard beeps.indices.contains(pitch) else { return }
        player.scheduleBuffer(beeps[pitch], at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    private func startEngine() -> Bool {
        if !isConfigured {
            engine.attach(environment)
            engine.attach(player)
            engine.connect(player, to: environment, format: format)
            engine.connect(environment, to: engine.mainMixerNode, format: nil)
            player.renderingAlgorithm = .HRTFHQ
            environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            isConfigured = true
        }
        guard !engine.isRunning else { return true }
        // The same session settings speech uses, so the two mix instead of cutting each other off.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
        try? session.setActive(true)
        do {
            try engine.start()
            return true
        } catch {
            log.error("Steering tones unavailable: \(error.localizedDescription)")
            return false
        }
    }

    private func stopEngine() {
        player.stop()
        if engine.isRunning { engine.pause() }
    }

    /// 70 ms of sine with 5 ms fades, so it clicks neither on nor off.
    private func makeBeep(frequency: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * 0.07)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frames
        let fade = Int(format.sampleRate * 0.005)
        for index in 0 ..< Int(frames) {
            let envelope = Float(min(1, Double(min(index, Int(frames) - 1 - index)) / Double(fade)))
            samples[index] = 0.5 * envelope * Float(sin(2 * .pi * frequency * Double(index) / format.sampleRate))
        }
        return buffer
    }
}
