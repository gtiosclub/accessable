import CoreGraphics
import Foundation
import Testing
import simd

@testable import SceneGeometry

// T34 — approaching people and vehicles: fitting world velocity to a track's positions, and
// predicting whether it reaches the walking path.
//
// The user stands at the world origin facing -Z, which is the corridor's own default
// convention, so a position of [0, 0, -8] is eight metres straight ahead and +x is to the
// right.

private let corridor = WalkingCorridor(
    origin: [0, 0, 0], forward: [0, 0, -1], right: [1, 0, 0],
    width: 0.9, maxDistance: 10
)

private func detection(
    label: String,
    trackID: UUID,
    position: SIMD3<Float>,
    bearing: RelativeBearing = .ahead
) -> Detection {
    Detection(
        trackID: trackID, label: label, confidence: 0.9,
        boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
        distance: Double(simd_length(position)), bearing: bearing,
        origin: .model, isHazard: true, worldPosition: position
    )
}

@Suite("T34 — fitting velocity to a track")
struct MotionHistoryTests {
    @Test("a steady walk comes out at the speed it was walked")
    func constantVelocity() throws {
        var history = MotionHistory()
        // 1.4 m/s toward the camera, sampled every 60 ms.
        for step in 0 ..< 8 {
            let time = Double(step) * 0.06
            history.record(position: [0, 0, -8 + 1.4 * Float(time)], at: time)
        }
        let motion = try #require(history.motion)
        #expect(abs(motion.velocity.z - 1.4) < 0.01)
        #expect(abs(motion.groundSpeed() - 1.4) < 0.01)
    }

    @Test("too few samples is no answer rather than a bad one")
    func notEnoughSamples() {
        var history = MotionHistory()
        history.record(position: [0, 0, -5], at: 0)
        history.record(position: [0, 0, -4.9], at: 0.06)
        #expect(history.motion == nil)
    }

    @Test("samples spanning too little time are refused")
    func tooShortASpan() {
        var history = MotionHistory()
        // Four samples, but only 30 ms apart in total: a small displacement over a small
        // interval is a large and meaningless velocity.
        for step in 0 ..< 4 {
            history.record(position: [0, 0, -5], at: Double(step) * 0.01)
        }
        #expect(history.motion == nil)
    }

    /// The reason for fitting rather than differencing. These offsets are a few centimetres
    /// of depth jitter on something standing still; frame-to-frame they would read as
    /// metres per second.
    @Test("depth jitter on a stationary object stays below the moving threshold")
    func jitterIsNotMotion() throws {
        let jitter: [Float] = [0.02, -0.03, 0.01, 0.03, -0.02, 0.0, 0.02, -0.01]
        var history = MotionHistory()
        for (step, offset) in jitter.enumerated() {
            history.record(position: [offset, 0, -5 + offset], at: Double(step) * 0.06)
        }
        let motion = try #require(history.motion)
        // Comfortably under ApproachTuning.minimumSpeed, so it never becomes a threat.
        #expect(motion.groundSpeed() < ApproachTuning.default.minimumSpeed)
    }

    @Test("vertical movement is not travel")
    func groundSpeedIgnoresHeight() {
        let motion = TrackMotion(
            position: [0, 0, -3], velocity: [0, 2.0, 0], sampleCount: 5, timeSpan: 0.3
        )
        // A detection box breathing up and down is not an approach.
        #expect(motion.groundSpeed() < 0.001)
    }

    @Test("a repeated or out-of-order timestamp is dropped")
    func outOfOrderIgnored() throws {
        var history = MotionHistory()
        for step in 0 ..< 5 {
            history.record(position: [0, 0, -5 + 0.1 * Float(step)], at: Double(step) * 0.06)
        }
        let before = try #require(history.motion)
        history.record(position: [0, 0, 100], at: 0.01)
        let after = try #require(history.motion)
        #expect(before == after)
    }
}

@Suite("T34 — motion per track")
struct MotionTrackerTests {
    @Test("two tracks keep separate velocities")
    func separateTracks() throws {
        let walker = UUID()
        let stander = UUID()
        var tracker = MotionTracker()
        var motions: [UUID: TrackMotion] = [:]
        for step in 0 ..< 8 {
            let time = Double(step) * 0.06
            motions = tracker.update([
                detection(label: "person", trackID: walker, position: [0, 0, -8 + 1.4 * Float(time)]),
                detection(label: "person", trackID: stander, position: [2, 0, -4]),
            ], at: time)
        }
        #expect(abs(try #require(motions[walker]).groundSpeed() - 1.4) < 0.02)
        #expect(try #require(motions[stander]).groundSpeed() < 0.001)
    }

    @Test("detections with nothing to measure are skipped")
    func skipsUnusableDetections() {
        var tracker = MotionTracker()
        var motions: [UUID: TrackMotion] = [:]
        let noPosition = Detection(
            trackID: UUID(), label: "person", confidence: 0.9,
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
            origin: .model, isHazard: true
        )
        let noTrack = Detection(
            label: "person", confidence: 0.9,
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
            origin: .model, isHazard: true, worldPosition: [0, 0, -5]
        )
        for step in 0 ..< 6 {
            motions = tracker.update([noPosition, noTrack], at: Double(step) * 0.06)
        }
        #expect(motions.isEmpty)
    }

    @Test("a track that stops being seen is forgotten")
    func staleTracksDropped() throws {
        let id = UUID()
        var tracker = MotionTracker()
        for step in 0 ..< 8 {
            _ = tracker.update(
                [detection(label: "person", trackID: id, position: [0, 0, -8 + 0.1 * Float(step)])],
                at: Double(step) * 0.06
            )
        }
        // Well past maximumAge with nothing to report.
        let motions = tracker.update([], at: 5.0)
        #expect(motions.isEmpty)
    }
}

@Suite("T34 — closest point of approach")
struct ClosestApproachTests {
    @Test("something coming straight at you arrives at the obvious time")
    func headOn() throws {
        // 10 m ahead, closing at 5 m/s.
        let approach = try #require(closestApproach(
            relativePosition: [0, 0, -10], relativeVelocity: [0, 0, 5]
        ))
        #expect(abs(approach.time - 2) < 0.001)
        #expect(approach.missDistance < 0.001)
        #expect(abs(approach.closingSpeed - 5) < 0.001)
    }

    @Test("something crossing ahead is predicted to miss by the gap it crosses at")
    func crossing() throws {
        // 5 m to the right and 5 m ahead, travelling left at 5 m/s: in one second it is
        // straight ahead, still 5 m away. Closing speed right now is nearly nothing, which
        // is why closing speed alone cannot see this case.
        let approach = try #require(closestApproach(
            relativePosition: [5, 0, -5], relativeVelocity: [-5, 0, 0]
        ))
        #expect(abs(approach.time - 1) < 0.001)
        #expect(abs(approach.missDistance - 5) < 0.001)
    }

    @Test("something already past has a negative time")
    func receding() throws {
        let approach = try #require(closestApproach(
            relativePosition: [0, 0, -10], relativeVelocity: [0, 0, -5]
        ))
        #expect(approach.time < 0)
        #expect(approach.closingSpeed < 0)
    }

    @Test("no relative motion means there is no approach to predict")
    func noRelativeMotion() {
        #expect(closestApproach(relativePosition: [0, 0, -5], relativeVelocity: .zero) == nil)
    }
}

@Suite("T34 — which approaches are warned about")
struct ApproachThreatTests
{
    /// Builds the motion a track would have been given, without running the fitter.
    private func motion(_ position: SIMD3<Float>, _ velocity: SIMD3<Float>) -> TrackMotion {
        TrackMotion(position: position, velocity: velocity, sampleCount: 6, timeSpan: 0.36)
    }

    @Test("a person walking toward you while you walk toward them is a threat")
    func headOnPerson() throws {
        let id = UUID()
        // Both at 1.4 m/s, 8 m apart: they meet in 8 / 2.8 seconds.
        let threats = approachThreats(
            detections: [detection(label: "person", trackID: id, position: [0, 0, -8])],
            motions: [id: motion([0, 0, -8], [0, 0, 1.4])],
            userVelocity: [0, 0, -1.4],
            corridor: corridor
        )
        let threat = try #require(threats.first)
        #expect(threat.trackID == id)
        #expect(abs(threat.timeToApproach - 8 / 2.8) < 0.05)
        #expect(threat.missDistance < 0.1)
    }

    /// The case the whole design turns on: closing speed is 1.4 m/s and the car is not
    /// approaching anybody. T16 already announces obstacles being walked toward.
    @Test("a parked car is not approaching, however fast you walk at it")
    func parkedCarIsNotAThreat() {
        let id = UUID()
        let threats = approachThreats(
            detections: [detection(label: "car", trackID: id, position: [0, 0, -8])],
            motions: [id: motion([0, 0, -8], .zero)],
            userVelocity: [0, 0, -1.4],
            corridor: corridor
        )
        #expect(threats.isEmpty)
    }

    @Test("a cyclist crossing the path ahead is a threat")
    func crossingCyclist() throws {
        let id = UUID()
        // 5 m to the right, 4 m ahead, travelling left at 4 m/s while the user stands still:
        // it reaches the user's line in 1.25 s, 4 m ahead of them.
        let threats = approachThreats(
            detections: [detection(
                label: "bicycle", trackID: id, position: [5, 0, -4],
                bearing: RelativeBearing(degrees: 51)
            )],
            motions: [id: motion([5, 0, -4], [-4, 0, 0])],
            userVelocity: .zero,
            corridor: WalkingCorridor(
                origin: [0, 0, -4], forward: [0, 0, -1], right: [1, 0, 0],
                width: 0.9, maxDistance: 10
            )
        )
        let threat = try #require(threats.first)
        #expect(abs(threat.timeToApproach - 1.25) < 0.05)
        #expect(threat.missDistance < 0.5)
    }

    @Test("a vehicle that will pass wide is left alone")
    func passingWideIsNotAThreat() {
        let id = UUID()
        // Travelling parallel to the user, three metres to the side.
        let threats = approachThreats(
            detections: [detection(label: "car", trackID: id, position: [3, 0, -10])],
            motions: [id: motion([3, 0, -10], [0, 0, 8])],
            userVelocity: .zero,
            corridor: corridor
        )
        #expect(threats.isEmpty)
    }

    @Test("only people and things on wheels are warned about")
    func unwatchedLabelsIgnored() {
        let id = UUID()
        let threats = approachThreats(
            detections: [detection(label: "chair", trackID: id, position: [0, 0, -5])],
            motions: [id: motion([0, 0, -5], [0, 0, 2])],
            userVelocity: .zero,
            corridor: corridor
        )
        #expect(threats.isEmpty)
    }

    @Test("anything beyond the trusted range is ignored")
    func tooFarIgnored() {
        let id = UUID()
        let far: SIMD3<Float> = [0, 0, -40]
        let threats = approachThreats(
            detections: [detection(label: "car", trackID: id, position: far)],
            motions: [id: motion(far, [0, 0, 12])],
            userVelocity: .zero,
            corridor: corridor
        )
        #expect(threats.isEmpty)
    }

    @Test("something already past is not warned about")
    func recedingIgnored() {
        let id = UUID()
        let threats = approachThreats(
            detections: [detection(label: "person", trackID: id, position: [0, 0, -3])],
            motions: [id: motion([0, 0, -3], [0, 0, -1.5])],
            userVelocity: .zero,
            corridor: corridor
        )
        #expect(threats.isEmpty)
    }

    @Test("the soonest approach comes first")
    func sortedSoonestFirst() throws {
        let near = UUID()
        let far = UUID()
        let threats = approachThreats(
            detections: [
                detection(label: "car", trackID: far, position: [0, 0, -12]),
                detection(label: "person", trackID: near, position: [0, 0, -3]),
            ],
            motions: [
                far: motion([0, 0, -12], [0, 0, 3]),
                near: motion([0, 0, -3], [0, 0, 1.5]),
            ],
            userVelocity: .zero,
            corridor: corridor
        )
        #expect(threats.count == 2)
        #expect(threats.first?.trackID == near)
    }
}

@Suite("T34 — what the user hears")
struct ApproachAnnouncerTests {
    private func threat(_ seconds: Float, label: String = "car", id: UUID = UUID()) -> ApproachThreat {
        ApproachThreat(
            trackID: id, label: label, timeToApproach: seconds, missDistance: 0.2,
            distance: seconds * 4, bearing: RelativeBearing(degrees: 60), speed: 4
        )
    }

    @Test("an imminent approach is announced on the first frame, not the second")
    func urgentIsImmediate() throws {
        var announcer = ApproachAnnouncer()
        let events = announcer.announcements(for: [threat(1.0)], at: 0)
        let event = try #require(events.first)
        #expect(event.priority == .critical)
        #expect(event.haptic == .stop)
        #expect(event.text.hasPrefix("Stop."))
    }

    @Test("a less urgent approach waits to be confirmed")
    func warningNeedsConfirmation() throws {
        var announcer = ApproachAnnouncer()
        let id = UUID()
        #expect(announcer.announcements(for: [threat(2.5, id: id)], at: 0).isEmpty)
        let events = announcer.announcements(for: [threat(2.5, id: id)], at: 0.06)
        #expect(try #require(events.first).priority == .high)
    }

    @Test("the same approach is not repeated frame after frame")
    func noRepeatWhileUnchanged() throws {
        var announcer = ApproachAnnouncer()
        let id = UUID()
        _ = announcer.announcements(for: [threat(1.0, id: id)], at: 0)
        for step in 1 ... 8 {
            let events = announcer.announcements(for: [threat(1.0, id: id)], at: Double(step) * 0.06)
            #expect(events.isEmpty)
        }
    }

    @Test("an approach becoming urgent is news again")
    func escalationSpeaks() throws {
        var announcer = ApproachAnnouncer()
        let id = UUID()
        _ = announcer.announcements(for: [threat(2.5, id: id)], at: 0)
        let first = announcer.announcements(for: [threat(2.5, id: id)], at: 0.06)
        #expect(try #require(first.first).priority == .high)
        // Now inside the urgent window: it interrupts rather than waiting for the cooldown.
        let second = announcer.announcements(for: [threat(1.0, id: id)], at: 0.12)
        #expect(try #require(second.first).priority == .critical)
    }

    @Test("the warning says which side it is coming from")
    func phrasing() {
        let right = ApproachThreat(
            trackID: UUID(), label: "car", timeToApproach: 2, missDistance: 0.2,
            distance: 8, bearing: RelativeBearing(degrees: 60), speed: 6
        )
        #expect(SpokenPhrasing.guidance(for: right, priority: .high) == "Car approaching from your right.")
        #expect(SpokenPhrasing.guidance(for: right, priority: .critical) == "Stop. Car from your right.")

        let behind = ApproachThreat(
            trackID: UUID(), label: "bicycle", timeToApproach: 2, missDistance: 0.2,
            distance: 8, bearing: RelativeBearing(degrees: 175), speed: 5
        )
        #expect(SpokenPhrasing.guidance(for: behind, priority: .high) == "Bicycle approaching from behind.")
    }
}
