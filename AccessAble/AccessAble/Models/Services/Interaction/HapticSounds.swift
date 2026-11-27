import AVFoundation
import os

private let log = Logger(subsystem: "AccessAble", category: "HapticSounds")

/// One tap (or short buzz) of a haptic, described the way an AHAP event is.
struct HapticTap: Sendable, Hashable {
    /// Seconds from the start of the pattern.
    var time: Double
    /// 0...1
    var intensity: Double
    /// 0 (dull, round) ... 1 (crisp, precise)
    var sharpness: Double
    /// nil for a transient tap; seconds for a continuous buzz.
    var duration: Double? = nil
}

extension InteractionHaptic {
    /// What this system haptic feels like, so it can be heard as well as felt, like the examples
    /// in Apple's Human Interface Guidelines ("Playing haptics").
    var taps: [HapticTap] {
        switch self {
        case .selection: [HapticTap(time: 0, intensity: 0.45, sharpness: 0.9)]
        case .light: [HapticTap(time: 0, intensity: 0.5, sharpness: 0.6)]
        case .medium: [HapticTap(time: 0, intensity: 0.75, sharpness: 0.5)]
        case .heavy: [HapticTap(time: 0, intensity: 1, sharpness: 0.3)]
        case .rigid: [HapticTap(time: 0, intensity: 0.85, sharpness: 1)]
        case .soft: [HapticTap(time: 0, intensity: 0.65, sharpness: 0)]
        // Two quick taps, the second stronger.
        case .success: [
            HapticTap(time: 0, intensity: 0.6, sharpness: 0.6),
            HapticTap(time: 0.1, intensity: 1, sharpness: 0.7),
        ]
        // Two quick taps, the second weaker.
        case .warning: [
            HapticTap(time: 0, intensity: 1, sharpness: 0.6),
            HapticTap(time: 0.15, intensity: 0.6, sharpness: 0.5),
        ]
        // Four rapid taps.
        case .error: [
            HapticTap(time: 0, intensity: 0.85, sharpness: 0.5),
            HapticTap(time: 0.07, intensity: 0.85, sharpness: 0.5),
            HapticTap(time: 0.14, intensity: 1, sharpness: 0.5),
            HapticTap(time: 0.3, intensity: 0.6, sharpness: 0.4),
        ]
        }
    }
}

extension HapticID {
    /// The taps in this ID's AHAP file, read from the file so the sound follows the design.
    /// Empty when the file is missing or unreadable.
    var ahapTaps: [HapticTap] {
        guard let url = ahapURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pattern = json["Pattern"] as? [[String: Any]]
        else { return [] }
        return pattern.compactMap { entry in
            guard let event = entry["Event"] as? [String: Any],
                  let type = event["EventType"] as? String,
                  type == "HapticTransient" || type == "HapticContinuous"
            else { return nil }
            var values: [String: Double] = [:]
            for parameter in event["EventParameters"] as? [[String: Any]] ?? [] {
                if let id = parameter["ParameterID"] as? String,
                   let value = (parameter["ParameterValue"] as? NSNumber)?.doubleValue {
                    values[id] = value
                }
            }
            return HapticTap(
                time: (event["Time"] as? NSNumber)?.doubleValue ?? 0,
                intensity: values["HapticIntensity"] ?? 1,
                sharpness: values["HapticSharpness"] ?? 0.5,
                duration: type == "HapticContinuous" ? (event["EventDuration"] as? NSNumber)?.doubleValue ?? 0.1 : nil
            )
        }
    }
}

/// Owner: User Interaction (3.4). Plays a click for every haptic, in time with it, so haptics
/// make a sound as well as a vibration. Dull haptics thud low, sharp ones click high, and
/// strength sets the volume. Stays silent while the microphone is listening, so it never
/// reaches the transcript.
@MainActor
final class HapticSounds {
    static let shared = HapticSounds()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [[HapticTap]: AVAudioPCMBuffer] = [:]
    private var isConfigured = false
    private var idleStop: Task<Void, Never>?
    /// The engine idles this long after the last click before it stops, so quick taps
    /// (scrolling a picker) don't restart it each time.
    private static let idleDelay: Duration = .seconds(2)

    func play(_ taps: [HapticTap], intensity: Float) {
        guard intensity > 0, !taps.isEmpty, startEngine(), let buffer = buffer(for: taps) else { return }
        player.volume = min(intensity, 1)
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.idleDelay)) != nil else { return }
            self?.stopEngine()
        }
    }

    private func startEngine() -> Bool {
        let session = AVAudioSession.sharedInstance()
        // Dictation owns the session while it records; a click would end up in the transcript.
        guard session.category != .record else { return false }
        if !isConfigured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            isConfigured = true
        }
        guard !engine.isRunning else { return true }
        // The same session settings speech and steering tones use, so they all mix.
        try? session.setCategory(
            .playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
        try? session.setActive(true)
        do {
            try engine.start()
            return true
        } catch {
            log.error("Haptic sounds unavailable: \(error.localizedDescription)")
            return false
        }
    }

    private func stopEngine() {
        player.stop()
        if engine.isRunning { engine.stop() }
        // Fails harmlessly while speech or steering tones are still playing.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func buffer(for taps: [HapticTap]) -> AVAudioPCMBuffer? {
        if let cached = buffers[taps] { return cached }
        let rate = format.sampleRate
        let tail = 0.06
        let end = taps.map { $0.time + ($0.duration ?? 0) }.max() ?? 0
        let frames = AVAudioFrameCount((end + tail) * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { samples[i] = 0 }
        var noise = SystemRandomNumberGenerator()
        for tap in taps {
            let sharpness = min(max(tap.sharpness, 0), 1)
            let amplitude = Float(min(max(tap.intensity, 0), 1)) * 0.7
            // Dull: a low, slowly fading thud. Sharp: a high click that is over almost at once.
            let frequency = 90 + 1_600 * pow(sharpness, 1.5)
            let decay = 0.004 + 0.022 * (1 - sharpness)
            let hold = tap.duration ?? 0
            let start = Int(tap.time * rate)
            let length = Int((hold + decay * 6) * rate)
            for n in 0..<length {
                let index = start + n
                guard index < Int(frames) else { break }
                let t = Double(n) / rate
                let attack = min(t / 0.0008, 1)
                let envelope = attack * (t < hold ? 1 : exp(-(t - hold) / decay))
                let tone = sin(2 * .pi * frequency * t)
                // A little noise on sharp taps gives them the "tick" of the real thing.
                let grit = Double.random(in: -1...1, using: &noise) * sharpness * 0.35 * exp(-t / 0.002)
                samples[index] += amplitude * Float(envelope * (tone + grit))
            }
        }
        for i in 0..<Int(frames) { samples[i] = max(-1, min(1, samples[i])) }
        buffers[taps] = buffer
        return buffer
    }
}
