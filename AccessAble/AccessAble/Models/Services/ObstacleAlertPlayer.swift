import AudioToolbox
import AVFoundation
import CoreHaptics
import os

private let log = Logger(subsystem: "AccessAble", category: "ObstacleAlert")

/// vibration + beep --> obstacle detected
actor ObstacleAlertPlayer: ObstacleAlerting {
    private var engine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    func alert(intensity: Float) async {
        guard supportsHaptics else {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            AudioServicesPlaySystemSound(1057) // short "tink"
            return
        }
        do {
            try play(intensity: intensity)
        } catch {
            engine = nil
            do {
                try play(intensity: intensity)
            } catch {
                log.error("obstacle alert failed: \(error.localizedDescription)")
            }
        }
    }

    private func play(intensity: Float) throws {
        let engine = try self.engine ?? makeEngine()
        self.engine = engine
        try engine.start() 
        let player = try engine.makePlayer(with: Self.pattern(intensity: intensity))
        try player.start(atTime: CHHapticTimeImmediate)
    }

    private func makeEngine() throws -> CHHapticEngine {
        // TODO(UI 3.3): move to the AnnouncementEngine once it owns the app's audio session.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setActive(true)

        let engine = try CHHapticEngine(audioSession: session)
        engine.playsHapticsOnly = false
        engine.isAutoShutdownEnabled = true
        return engine
    }

    /// Two short, strong buzzes, each with a short tone.
    private static func pattern(intensity: Float) throws -> CHHapticPattern {
        let strength = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
        let volume = CHHapticEventParameter(parameterID: .audioVolume, value: 0.8)
        let pitch = CHHapticEventParameter(parameterID: .audioPitch, value: 0.3)
        let events = [0.0, 0.18].flatMap { time in
            [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [strength, sharpness], relativeTime: time, duration: 0.12),
                CHHapticEvent(eventType: .audioContinuous, parameters: [volume, pitch], relativeTime: time, duration: 0.12),
            ]
        }
        return try CHHapticPattern(events: events, parameters: [])
    }
}
