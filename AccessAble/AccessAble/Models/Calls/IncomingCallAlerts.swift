import AVFAudio
import Foundation
import SwiftUI
import os

@MainActor
protocol IncomingCallAlerting: AnyObject {
    func start()
    func stop()
    func announce(_ text: String)
}

/// An app-owned, original ring asset. No private system-sound IDs, push, or CallKit.
@MainActor
final class IncomingCallAlerts: IncomingCallAlerting {
    private let haptics: any HapticRendering
    private var player: AVAudioPlayer?
    private var hapticTask: Task<Void, Never>?
    private let log = Logger(subsystem: "AccessAble", category: "IncomingCall")

    init(haptics: any HapticRendering) { self.haptics = haptics }

    func start() {
        stop()
        let url = Bundle.main.url(forResource: "incoming-call", withExtension: "wav")
            ?? Bundle.main.url(forResource: "incoming-call", withExtension: "wav", subdirectory: "Calls")
            ?? Bundle.main.url(forResource: "incoming-call", withExtension: "wav", subdirectory: "Resources/Calls")
        if let url {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                player.volume = 0.2 // Keep VoiceOver intelligible over the ring.
                player.prepareToPlay()
                player.play()
                self.player = player
            } catch { log.error("Couldn't play the incoming-call sound.") }
        } else { log.error("Incoming-call sound resource is missing from the app bundle.") }
        // Do not change the shared AVAudioSession category or deactivate VoiceOver/speech.
        // LiveKit configures its own audio after this player has stopped.
        hapticTask = Task { [haptics] in
            while !Task.isCancelled {
                await haptics.play(.attention, intensity: 1)
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        hapticTask?.cancel()
        hapticTask = nil
        // Each haptic is a short pattern; cancellation stops subsequent repeats without
        // cancelling unrelated guidance haptics on the shared renderer.
    }

    func announce(_ text: String) { AccessibilityNotification.Announcement(text).post() }
}
