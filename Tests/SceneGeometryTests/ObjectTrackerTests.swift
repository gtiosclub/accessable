import CoreGraphics
import Foundation
import Testing
@testable import SceneGeometry

@Suite("T15 — object tracking")
struct ObjectTrackerTests {
    @Test("retains an ID and reports velocity for a high-IoU same-label match")
    func retainsIDAndComputesVelocity() throws {
        var tracker = ObjectTracker(minimumIoU: 0.3)
        let firstTime = Date(timeIntervalSinceReferenceDate: 100)
        let first = try #require(tracker.track([
            detection(label: "person", box: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.5))
        ], at: firstTime).first)

        let second = try #require(tracker.track([
            detection(label: "person", box: CGRect(x: 0.42, y: 0.2, width: 0.2, height: 0.5))
        ], at: firstTime.addingTimeInterval(1)).first)

        #expect(second.id == first.id)
        #expect(abs(second.imageVelocity.dx - 0.02) < 0.0001)
        #expect(abs(second.imageVelocity.dy) < 0.0001)
        #expect(second.lastSeen == firstTime.addingTimeInterval(1))
    }

    @Test("does not match detections with different labels")
    func labelsMustMatch() throws {
        var tracker = ObjectTracker(minimumIoU: 0)
        let time = Date(timeIntervalSinceReferenceDate: 100)
        let person = try #require(tracker.track([
            detection(label: "person", box: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        ], at: time).first)

        let chair = try #require(tracker.track([
            detection(label: "chair", box: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        ], at: time.addingTimeInterval(1)).first)

        #expect(chair.id != person.id)
    }

    @Test("creates a new track when IoU is below the threshold")
    func lowIoUCreatesNewTrack() throws {
        var tracker = ObjectTracker(minimumIoU: 0.5)
        let time = Date(timeIntervalSinceReferenceDate: 100)
        let first = try #require(tracker.track([
            detection(label: "person", box: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        ], at: time).first)
        let second = try #require(tracker.track([
            detection(label: "person", box: CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2))
        ], at: time.addingTimeInterval(1)).first)

        #expect(second.id != first.id)
    }

    @Test("does not match disjoint boxes at a zero IoU threshold")
    func zeroThresholdStillRequiresOverlap() throws {
        var tracker = ObjectTracker(minimumIoU: 0)
        let time = Date(timeIntervalSinceReferenceDate: 100)
        let first = try #require(tracker.track([
            detection(label: "person", box: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        ], at: time).first)

        let second = try #require(tracker.track([
            detection(label: "person", box: CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2))
        ], at: time.addingTimeInterval(1)).first)

        #expect(second.id != first.id)
    }

    @Test("matches multiple objects one-to-one")
    func matchesMultipleObjects() throws {
        var tracker = ObjectTracker(minimumIoU: 0.3)
        let time = Date(timeIntervalSinceReferenceDate: 100)
        let initial = tracker.track([
            detection(label: "person", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            detection(label: "person", box: CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2)),
        ], at: time)

        let updated = tracker.track([
            detection(label: "person", box: CGRect(x: 0.62, y: 0.1, width: 0.2, height: 0.2)),
            detection(label: "person", box: CGRect(x: 0.12, y: 0.1, width: 0.2, height: 0.2)),
        ], at: time.addingTimeInterval(1))

        #expect(updated[0].id == initial[1].id)
        #expect(updated[1].id == initial[0].id)
    }

    @Test("removes a track after its allowed missed frames")
    func expiresMissedTracks() throws {
        var tracker = ObjectTracker(maximumMissedFrames: 1)
        let time = Date(timeIntervalSinceReferenceDate: 100)
        let original = try #require(tracker.track([
            detection(label: "person", box: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        ], at: time).first)

        #expect(tracker.track([], at: time.addingTimeInterval(1)).isEmpty)
        #expect(tracker.activeTracks[original.id] != nil)
        #expect(tracker.track([], at: time.addingTimeInterval(2)).isEmpty)
        #expect(tracker.activeTracks[original.id] == nil)
    }

    @Test("preserves state across out-of-order frames")
    func outOfOrderFramesDoNotRegressState() throws {
        var tracker = ObjectTracker()
        let time = Date(timeIntervalSinceReferenceDate: 100)
        let first = try #require(tracker.track([
            detection(label: "person", box: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        ], at: time).first)

        let stale = tracker.track([
            detection(label: "person", box: CGRect(x: 0.25, y: 0.2, width: 0.2, height: 0.2))
        ], at: time)

        #expect(stale.isEmpty)
        #expect(tracker.activeTracks[first.id]?.boundingBox == first.boundingBox)
        #expect(tracker.activeTracks[first.id]?.lastSeen == first.lastSeen)

        let next = try #require(tracker.track([
            detection(label: "person", box: CGRect(x: 0.3, y: 0.2, width: 0.2, height: 0.2))
        ], at: time.addingTimeInterval(1)).first)

        #expect(abs(next.imageVelocity.dx - 0.1) < 0.0001)
        #expect(abs(next.imageVelocity.dy) < 0.0001)
    }

    @Test("a stale frame neither creates nor expires tracks")
    func staleFramesHaveNoSideEffects() {
        var tracker = ObjectTracker(minimumIoU: 0.5, maximumMissedFrames: 0)
        let time = Date(timeIntervalSinceReferenceDate: 100)
        let initial = tracker.track([
            detection(label: "person", box: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2)),
            detection(label: "person", box: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.2)),
        ], at: time)

        let stale = tracker.track([
            detection(label: "person", box: CGRect(x: 0.9, y: 0.2, width: 0.1, height: 0.1))
        ], at: time.addingTimeInterval(-1))

        #expect(stale.isEmpty)
        #expect(tracker.activeTracks.count == 2)
        #expect(initial.allSatisfy { tracker.activeTracks[$0.id] != nil })
    }

    private func detection(label: String, box: CGRect) -> Detection {
        Detection(
            label: label,
            confidence: 0.9,
            boundingBox: box,
            origin: .model,
            isHazard: false
        )
    }
}
