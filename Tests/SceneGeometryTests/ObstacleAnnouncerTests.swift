import CoreGraphics
import Foundation
import Testing
@testable import SceneGeometry

@Suite("T16 — obstacle announcements")
struct ObstacleAnnouncerTests {
    private let chairID = UUID()

    private func chair(at distance: Double, inPath: Bool = true) -> ObstacleAlertInput {
        ObstacleAlertInput(
            detection: Detection(
                trackID: chairID, label: "chair", confidence: 0.9,
                boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
                distance: distance, bearing: .ahead, origin: .geometric, isHazard: true
            ),
            isInPath: inPath
        )
    }

    /// Feeds one object per frame, 0.1 s apart, and returns what each frame announced.
    private func run(_ frames: [ObstacleAlertInput?], announcer: inout ObstacleAnnouncer) -> [[AnnouncementEvent]] {
        frames.enumerated().map { index, object in
            announcer.announcements(for: object.map { [$0] } ?? [], hazards: [], at: Double(index) * 0.1)
        }
    }

    @Test("announces on entry and on each nearer threshold, never repeating a band")
    func thresholdCrossings() {
        var announcer = ObstacleAnnouncer()
        let events = run([
            chair(at: 3.2, inPath: false),
            chair(at: 2.9),
            chair(at: 2.7),
            chair(at: 1.9),
            chair(at: 1.8),
            chair(at: 0.9),
        ], announcer: &announcer)

        #expect(events.map(\.count) == [0, 1, 0, 1, 0, 1])
        #expect(events[1].first?.priority == .normal)
        #expect(events[1].first?.haptic == .obstacleNear)
        #expect(events[3].first?.priority == .high)
        #expect(events[3].first?.haptic == .obstacleNearer)
        #expect(events[5].first?.priority == .critical)
        #expect(events[5].first?.haptic == .stop)
        #expect(events[5].first?.text.hasPrefix("Stop. Chair") == true)
    }

    @Test("an object first seen up close goes straight to the urgent announcement")
    func firstSeenClose() {
        var announcer = ObstacleAnnouncer()
        let events = run([chair(at: 0.8)], announcer: &announcer)
        #expect(events[0].map(\.priority) == [.critical])
    }

    @Test("flickering out of the corridor does not repeat the announcement")
    func ignoresFlicker() {
        var announcer = ObstacleAnnouncer()
        let events = run([chair(at: 2.5), chair(at: 2.5, inPath: false), chair(at: 2.4)], announcer: &announcer)
        #expect(events.map(\.count) == [1, 0, 0])
    }

    @Test("leaving the corridor for longer than the grace period makes re-entry news again")
    func reentryAfterGracePeriod() {
        var announcer = ObstacleAnnouncer()
        announcer.exitGracePeriod = 0.25
        let events = run([
            chair(at: 2.5),
            chair(at: 2.5, inPath: false),
            chair(at: 2.5, inPath: false),
            chair(at: 2.5, inPath: false),
            chair(at: 2.5),
        ], announcer: &announcer)
        #expect(events.map(\.count) == [1, 0, 0, 0, 1])
    }

    @Test("moving away and back within the same band stays quiet")
    func recedingDoesNotRepeat() {
        var announcer = ObstacleAnnouncer()
        let events = run([chair(at: 1.9), chair(at: 2.6), chair(at: 1.9)], announcer: &announcer)
        #expect(events.map(\.count) == [1, 0, 0])
    }

    @Test("objects beyond the outermost threshold, or without a track or distance, are ignored")
    func ignoresIneligible() {
        var announcer = ObstacleAnnouncer()
        var untracked = chair(at: 1).detection
        untracked.trackID = nil
        var unmeasured = chair(at: 1).detection
        unmeasured.distance = nil

        let events = announcer.announcements(
            for: [chair(at: 3.5), ObstacleAlertInput(detection: untracked, isInPath: true),
                  ObstacleAlertInput(detection: unmeasured, isInPath: true)],
            hazards: [], at: 0
        )
        #expect(events.isEmpty)
    }

    @Test("forgotten objects are announced afresh")
    func forgetsOldState() {
        var announcer = ObstacleAnnouncer()
        announcer.forgetAfter = 1
        #expect(announcer.announcements(for: [chair(at: 2.5)], hazards: [], at: 0).count == 1)
        #expect(announcer.announcements(for: [], hazards: [], at: 2).isEmpty)
        #expect(announcer.announcements(for: [chair(at: 2.5)], hazards: [], at: 2.1).count == 1)
    }

    @Test("a drop-off is at least high priority and announced once per band")
    func elevationHazards() throws {
        var announcer = ObstacleAnnouncer()
        let far = [ElevationHazard(type: .dropOff, distance: 2.8, heightChange: -0.4)]
        let first = announcer.announcements(for: [], hazards: far, at: 0)
        let repeated = announcer.announcements(for: [], hazards: far, at: 0.1)

        let event = try #require(first.first)
        #expect(first.count == 1 && repeated.isEmpty)
        #expect(event.priority == .high)
        #expect(event.text == "Drop-off 3 metres ahead.")
        #expect(event.category == .hazard && event.source == .obstacleDetection)
    }

    @Test("events expire quickly and carry a per-object, per-band dedup key")
    func eventMetadata() throws {
        var announcer = ObstacleAnnouncer()
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let event = try #require(announcer.announcements(for: [chair(at: 1.5)], hazards: [], at: 0, now: now).first)

        #expect(event.expiresAt == now.addingTimeInterval(1.5))
        #expect(event.dedupKey == "obstacle-\(chairID.uuidString)-1")
        #expect(event.bearing == .ahead)
    }
}
