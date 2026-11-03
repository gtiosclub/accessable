import Foundation
import Testing
@testable import AccessAble

private actor RecordingHaptics: HapticRendering {
    private(set) var played: [(id: HapticID, intensity: Float)] = []
    private(set) var stops = 0

    func play(_ id: HapticID, intensity: Float) async { played.append((id, intensity)) }
    func stop() async { stops += 1 }
}

/// Haptics only, so the tests stay silent and don't wait on speech.
@MainActor
struct AnnouncementEngineTests {
    private func makeEngine(_ haptics: RecordingHaptics) async -> AnnouncementEngine {
        let engine = AnnouncementEngine(speech: SpeechOutput(), haptics: haptics)
        var profile = GuidanceProfile.blind
        profile.channels = [.haptics]
        await engine.updateProfile(profile)
        return engine
    }

    /// Submits an event and waits until the engine has finished rendering it.
    private func deliver(_ event: AnnouncementEvent, to engine: AnnouncementEngine) async {
        let delivered = engine.deliveredEvents()
        await engine.submit(event)
        for await _ in delivered { break }
        // Delivery is announced just before the haptic is rendered.
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func warning(_ haptic: HapticID?, distance: Double? = nil, key: String) -> AnnouncementEvent {
        AnnouncementEvent(
            category: .hazard, priority: .critical, text: key, haptic: haptic,
            distance: distance, source: .obstacleDetection, dedupKey: key
        )
    }

    @Test
    func aWarningPlaysItsHapticScaledByDistance() async throws {
        let haptics = RecordingHaptics()
        let engine = await makeEngine(haptics)

        await deliver(warning(.stop, distance: 0.5, key: "near"), to: engine)
        await deliver(warning(.stop, distance: 5, key: "far"), to: engine)

        let played = await haptics.played
        #expect(played.map(\.id) == [.stop, .stop])
        #expect(abs(played[0].intensity - 1.0) < 0.001)
        #expect(abs(played[1].intensity - 0.45) < 0.001)
    }

    @Test
    func pathClearStopsAStillLoopingWarning() async {
        let haptics = RecordingHaptics()
        let engine = await makeEngine(haptics)

        await deliver(warning(.stop, key: "stop"), to: engine)
        #expect(await haptics.stops == 0)
        await deliver(warning(nil, key: "clear"), to: engine)
        #expect(await haptics.stops == 1)
    }

    @Test
    func aSilentNonHazardEventLeavesAWarningAlone() async {
        let haptics = RecordingHaptics()
        let engine = await makeEngine(haptics)

        await deliver(
            AnnouncementEvent(category: .maneuver, priority: .high, text: "Turn left soon", source: .navigation),
            to: engine
        )
        #expect(await haptics.stops == 0)
    }

    @Test
    func pausingStopsHaptics() async {
        let haptics = RecordingHaptics()
        let engine = await makeEngine(haptics)

        await engine.pause()
        #expect(await haptics.stops == 1)
    }
}
