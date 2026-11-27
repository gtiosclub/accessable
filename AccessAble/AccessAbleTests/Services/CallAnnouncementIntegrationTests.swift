import Foundation
import Testing
@testable import AccessAble

@MainActor
struct CallAnnouncementIntegrationTests {
    @Test func engineUsesLivePreferencesAndRepeatCannotBypassDisabledObstacles() async throws {
        let settings = CallerSettings()
        settings.preferences.criticalObstacleAlerts = false
        let engine = AnnouncementEngine(speech: SpeechOutput(), haptics: CallPolicyTestHaptics(), callSettings: settings)
        var profile = GuidanceProfile.blind
        profile.channels = [.haptics]
        await engine.updateProfile(profile)
        await engine.setInCall(true)
        let firstStream = engine.deliveredEvents()
        await engine.submit(warning("off"))
        let maneuver = AnnouncementEvent(category: .maneuver, priority: .high, text: "turn", source: .navigation)
        await engine.submit(maneuver)
        #expect(try await first(firstStream).id == maneuver.id)

        settings.preferences.criticalObstacleAlerts = true
        let secondStream = engine.deliveredEvents()
        let enabled = warning("on")
        await engine.submit(enabled)
        #expect(try await first(secondStream).id == enabled.id)

        settings.preferences.criticalObstacleAlerts = false
        let thirdStream = engine.deliveredEvents()
        await engine.repeatLast()
        let next = AnnouncementEvent(category: .maneuver, priority: .high, text: "another turn", source: .navigation)
        await engine.submit(next)
        #expect(try await first(thirdStream).id == next.id)
        await engine.setInCall(false)
        await engine.pause()
    }

    private func warning(_ key: String) -> AnnouncementEvent {
        AnnouncementEvent(category: .hazard, priority: .critical, text: key, haptic: .stop,
                          source: .obstacleDetection, dedupKey: key)
    }

    private func first(_ stream: AsyncStream<AnnouncementEvent>) async throws -> AnnouncementEvent {
        try await withThrowingTaskGroup(of: AnnouncementEvent.self) { group in
            group.addTask { for await event in stream { return event }; throw CallSessionError.notConfigured }
            group.addTask { try await Task.sleep(for: .seconds(2)); throw CallSessionError.notConfigured }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CallSessionError.notConfigured }
            return value
        }
    }
}
private actor CallPolicyTestHaptics: HapticRendering {
    func play(_ id: HapticID, intensity: Float) async {}
    func stop() async {}
}
