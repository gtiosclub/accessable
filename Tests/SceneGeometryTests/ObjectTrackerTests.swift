import CoreGraphics
import Foundation
import Testing
@testable import SceneGeometry

@Suite("T15 — object tracking")
struct ObjectTrackerTests {
    private func detection(_ label: String, _ box: CGRect) -> Detection {
        Detection(label: label, confidence: 0.9, boundingBox: box, origin: .model, isHazard: false)
    }

    @Test("an overlapping same-label detection keeps its ID")
    func keepsID() throws {
        var tracker = ObjectTracker()
        let first = try #require(tracker.update([detection("person", CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.5))], at: 100).first)
        let second = try #require(tracker.update([detection("person", CGRect(x: 0.42, y: 0.2, width: 0.2, height: 0.5))], at: 100.1).first)

        #expect(first.trackID != nil)
        #expect(second.trackID == first.trackID)
    }

    @Test("different specific labels never share a track")
    func labelsMustMatch() throws {
        var tracker = ObjectTracker()
        tracker.minimumIoU = 0
        let box = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let person = try #require(tracker.update([detection("person", box)], at: 100).first)
        let chair = try #require(tracker.update([detection("chair", box)], at: 100.1).first)

        #expect(chair.trackID != person.trackID)
    }

    @Test("a fused chair that drops back to a plain obstacle stays the same chair")
    func genericObstacleLabelIsCompatible() throws {
        var tracker = ObjectTracker()
        let box = CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.3)
        let chair = try #require(tracker.update([detection("chair", box)], at: 100).first)
        let unlabelled = try #require(tracker.update([detection(Detection.obstacleLabel, box)], at: 100.1).first)

        #expect(unlabelled.trackID == chair.trackID)
        #expect(unlabelled.label == "chair")
    }

    @Test("boxes below the overlap threshold start a new track, even at threshold zero")
    func lowOverlapCreatesNewTrack() throws {
        var tracker = ObjectTracker()
        tracker.minimumIoU = 0
        let first = try #require(tracker.update([detection("person", CGRect(x: 0, y: 0, width: 0.2, height: 0.2))], at: 100).first)
        let second = try #require(tracker.update([detection("person", CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2))], at: 100.1).first)

        #expect(second.trackID != first.trackID)
    }

    @Test("multiple objects match one-to-one and keep their input order")
    func matchesMultipleObjects() {
        var tracker = ObjectTracker()
        let initial = tracker.update([
            detection("person", CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            detection("person", CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2)),
        ], at: 100)
        let updated = tracker.update([
            detection("person", CGRect(x: 0.62, y: 0.1, width: 0.2, height: 0.2)),
            detection("person", CGRect(x: 0.12, y: 0.1, width: 0.2, height: 0.2)),
        ], at: 100.1)

        #expect(updated[0].trackID == initial[1].trackID)
        #expect(updated[1].trackID == initial[0].trackID)
    }

    @Test("a track survives a short gap but expires after maximumAge")
    func expiresByAge() throws {
        var tracker = ObjectTracker()
        tracker.maximumAge = 0.5
        let box = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let original = try #require(tracker.update([detection("person", box)], at: 100).first?.trackID)

        #expect(tracker.update([], at: 100.3).isEmpty)
        #expect(tracker.activeTrackIDs.contains(original))
        let recovered = try #require(tracker.update([detection("person", box)], at: 100.4).first)
        #expect(recovered.trackID == original)

        _ = tracker.update([], at: 101)
        #expect(!tracker.activeTrackIDs.contains(original))
        let reappeared = try #require(tracker.update([detection("person", box)], at: 101.1).first)
        #expect(reappeared.trackID != original)
    }
}
