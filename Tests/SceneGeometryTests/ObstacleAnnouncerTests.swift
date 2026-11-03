import CoreGraphics
import Foundation
import Testing
@testable import SceneGeometry

@Suite("T16 — path announcements")
struct ObstacleAnnouncerTests {
    private func object(_ label: String = "chair", at distance: Double?, inPath: Bool = true, bearing: RelativeBearing = .ahead) -> ObstacleAlertInput {
        ObstacleAlertInput(
            detection: Detection(
                trackID: UUID(), label: label, confidence: 0.9,
                boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
                distance: distance, bearing: bearing, origin: .geometric, isHazard: true
            ),
            isInPath: inPath
        )
    }

    private func chair(at distance: Double, inPath: Bool = true) -> ObstacleAlertInput {
        object(at: distance, inPath: inPath)
    }

    /// The three-band configuration, for tests of the band mechanics themselves.
    private func three() -> ObstacleAnnouncer {
        var announcer = ObstacleAnnouncer()
        announcer.thresholds = [3, 2, 1]
        return announcer
    }

    /// Feeds one frame per entry, `step` seconds apart, and returns what each frame announced.
    private func run(
        _ frames: [ObstacleAlertInput?],
        path: [PathAssessment?]? = nil,
        step: TimeInterval = 0.1,
        announcer: inout ObstacleAnnouncer
    ) -> [[AnnouncementEvent]] {
        frames.enumerated().map { index, frame in
            announcer.announcements(
                for: frame.map { [$0] } ?? [],
                hazards: [],
                path: path?[index],
                at: Double(index) * step
            )
        }
    }

    // MARK: Bands

    @Test("by default there are two bands: a warning at 2.5 m and a stop at 1.2 m")
    func defaultBands() {
        var announcer = ObstacleAnnouncer()
        let events = run([chair(at: 2.6), chair(at: 2.6), chair(at: 2.4), chair(at: 2.4), chair(at: 1.1), chair(at: 1.1)], announcer: &announcer)
        #expect(events.map(\.count) == [0, 0, 0, 1, 0, 1])
        #expect(events[3].first?.priority == .high)
        #expect(events[3].first?.text == "Chair ahead.")
        #expect(events[5].first?.priority == .critical)
        #expect(events[5].first?.text == "Stop. Chair ahead.")
        #expect(events[5].first?.haptic == .stop)
    }

    @Test("with three bands, the farthest is an information notice with the distance")
    func thresholdCrossings() {
        var announcer = three()
        let events = run([
            chair(at: 3.2, inPath: false), chair(at: 3.2, inPath: false),
            chair(at: 2.9), chair(at: 2.9),
            chair(at: 2.7),
            chair(at: 1.9), chair(at: 1.9),
            chair(at: 1.8),
            chair(at: 0.9), chair(at: 0.9),
        ], announcer: &announcer)

        #expect(events.map(\.count) == [0, 0, 0, 1, 0, 0, 1, 0, 0, 1])
        #expect(events[3].first?.priority == .normal)
        #expect(events[3].first?.haptic == .obstacleNear)
        #expect(events[3].first?.text == "Chair ahead, 3 metres.")
        #expect(events[6].first?.priority == .high)
        #expect(events[6].first?.haptic == .obstacleNearer)
        #expect(events[6].first?.text == "Chair ahead.")
        #expect(events[9].first?.priority == .critical)
        #expect(events[9].first?.text == "Stop. Chair ahead.")
    }

    @Test("an object first seen up close goes straight to the urgent announcement")
    func firstSeenClose() {
        var announcer = ObstacleAnnouncer()
        let events = run([chair(at: 0.8), chair(at: 0.8)], announcer: &announcer)
        #expect(events.map { $0.map(\.priority) } == [[], [.critical]])
    }

    @Test("a single frame of speckle is never spoken")
    func singleFrameIgnored() {
        var announcer = ObstacleAnnouncer()
        let events = run([chair(at: 0.8), nil, nil, chair(at: 2.4), nil, chair(at: 1.5), nil], announcer: &announcer)
        #expect(events.map(\.count) == Array(repeating: 0, count: events.count))
    }

    @Test("flickering out of the corridor does not repeat the announcement")
    func ignoresFlicker() {
        var announcer = three()
        let events = run([
            chair(at: 2.5), chair(at: 2.5), chair(at: 2.5, inPath: false), chair(at: 2.4),
            chair(at: 2.4, inPath: false), chair(at: 2.4),
        ], announcer: &announcer)
        #expect(events.map(\.count) == [0, 1, 0, 0, 0, 0])
    }

    @Test("an object sitting on a threshold does not toggle bands")
    func hysteresis() {
        var announcer = three()
        let events = run([
            chair(at: 1.95), chair(at: 1.95),
            chair(at: 2.2), chair(at: 2.2), chair(at: 2.2),
            chair(at: 1.9), chair(at: 1.9),
        ], announcer: &announcer)
        #expect(events.map(\.count) == [0, 1, 0, 0, 0, 0, 0])
    }

    @Test("moving away is silent, but coming back in is announced again")
    func recedingThenApproaching() {
        var announcer = three()
        let events = run([
            chair(at: 1.9), chair(at: 1.9),
            chair(at: 2.6), chair(at: 2.6),
            chair(at: 1.9), chair(at: 1.9),
        ], step: 1, announcer: &announcer)
        #expect(events.map(\.count) == [0, 1, 0, 0, 0, 1])
        #expect(events[5].first?.priority == .high)
    }

    @Test("the nearest thing in the path sets the state, whatever its identity")
    func nearestWins() {
        var announcer = ObstacleAnnouncer()
        let frame = [object("chair", at: 2.8), object("wall", at: 1.9), object("person", at: 2.2, inPath: false)]
        let first = announcer.announcements(for: frame, hazards: [], at: 0)
        let second = announcer.announcements(for: frame, hazards: [], at: 0.1)
        #expect(first.isEmpty)
        #expect(second.map(\.text) == ["Wall ahead."])
    }

    // MARK: The map decides

    @Test("when the map is consulted, it decides whether the path is blocked")
    func mapDecides() {
        var announcer = ObstacleAnnouncer()
        let blocked = BlockedAhead(distance: 1.0)
        _ = announcer.announcements(for: [], hazards: [], blockedAhead: blocked, at: 0)
        let event = announcer.announcements(for: [], hazards: [], blockedAhead: blocked, at: 0.1).first
        #expect(event?.text == "Stop. Obstacle ahead.")
        #expect(event?.priority == .critical)
    }

    @Test("a detection at the map's distance lends its name")
    func mapWithName() {
        var announcer = ObstacleAnnouncer()
        let blocked = BlockedAhead(distance: 1.0)
        let frame = [object("chair", at: 1.2), object("person", at: 3.0)]
        _ = announcer.announcements(for: frame, hazards: [], blockedAhead: blocked, at: 0)
        #expect(announcer.announcements(for: frame, hazards: [], blockedAhead: blocked, at: 0.1).first?.text == "Stop. Chair ahead.")
    }

    @Test("a detection the map does not confirm is not announced")
    func mapOverridesDetections() {
        var announcer = ObstacleAnnouncer()
        let clear = BlockedAhead(distance: nil)
        let counts = (0 ..< 4).map { announcer.announcements(for: [chair(at: 1.0)], hazards: [], blockedAhead: clear, at: Double($0) * 0.1).count }
        #expect(counts == [0, 0, 0, 0])
    }

    // MARK: Clearing and re-arming

    @Test("after a stop, an empty corridor earns one \"Path clear\"")
    func pathClear() {
        var announcer = ObstacleAnnouncer()
        let events = run([chair(at: 0.9), chair(at: 0.9), nil, nil, nil, nil, nil], step: 0.5, announcer: &announcer)
        #expect(events.map(\.count) == [0, 1, 0, 0, 0, 0, 1])
        #expect(events[6].first?.text == "Path clear.")
        #expect(events[6].first?.priority == .normal)
        #expect(events[6].first?.dedupKey == "path-clear")
    }

    @Test("a warning that never became a stop is not followed by \"Path clear\"")
    func noClearAfterWarningOnly() {
        var announcer = ObstacleAnnouncer()
        let events = run([chair(at: 1.9), chair(at: 1.9), nil, nil, nil, nil, nil], step: 0.5, announcer: &announcer)
        #expect(events.map(\.count) == [0, 1, 0, 0, 0, 0, 0])
    }

    @Test("the same band re-entering right after clearing waits for the re-arm interval")
    func rearm() {
        var announcer = ObstacleAnnouncer()
        let events = run([
            chair(at: 0.9), chair(at: 0.9), nil, nil, nil, nil, nil,
            chair(at: 0.9), chair(at: 0.9), chair(at: 0.9),
        ], step: 0.5, announcer: &announcer)
        #expect(events.map(\.count) == [0, 1, 0, 0, 0, 0, 1, 0, 0, 1])
    }

    @Test("a persisting stop warning is repeated, but only every repeat interval")
    func reminder() {
        var announcer = ObstacleAnnouncer()
        let events = run(Array(repeating: chair(at: 0.8), count: 10), step: 1, announcer: &announcer)
        #expect(events.map(\.count) == [0, 1, 0, 0, 0, 0, 0, 0, 0, 1])
    }

    // MARK: Advice

    @Test("the warning carries the way round, and a change of advice is news after its cooldown")
    func advice() {
        var announcer = ObstacleAnnouncer()
        let left = PathAssessment(clearDirection: .left, sidestep: -0.7)
        let right = PathAssessment(clearDirection: .right, sidestep: 0.7)
        let events = run(
            Array(repeating: chair(at: 1.9), count: 6),
            path: [left, left, right, right, right, right],
            step: 1,
            announcer: &announcer
        )
        #expect(events.map(\.count) == [0, 1, 0, 0, 0, 1])
        #expect(events[1].first?.text == "Chair ahead. Go left.")
        #expect(events[5].first?.text == "Chair ahead. Go right.")
    }

    @Test("a direction that flips for one frame never reaches the user")
    func adviceDebounced() {
        var announcer = ObstacleAnnouncer()
        let left = PathAssessment(clearDirection: .left, sidestep: -0.7)
        let right = PathAssessment(clearDirection: .right, sidestep: 0.7)
        let events = run(
            Array(repeating: chair(at: 1.9), count: 8),
            path: [left, left, right, left, left, left, left, left],
            step: 1,
            announcer: &announcer
        )
        #expect(events.map(\.count) == [0, 1, 0, 0, 0, 0, 0, 0])
    }

    @Test("advice is left off a three-band information notice")
    func noAdviceFarOut() {
        var announcer = three()
        let left = PathAssessment(clearDirection: .left, sidestep: -0.7)
        let events = run([chair(at: 2.9), chair(at: 2.9)], path: [left, left], announcer: &announcer)
        #expect(events[1].first?.text == "Chair ahead, 3 metres.")
    }

    @Test("a blocked path up close says so")
    func blocked() {
        var announcer = ObstacleAnnouncer()
        let events = run([object("wall", at: 0.7), object("wall", at: 0.7)], path: [.blocked, .blocked], announcer: &announcer)
        #expect(events[1].first?.text == "Stop. Wall ahead. No clear path. Turn around slowly.")
    }

    @Test("a blocked path with room on one side says which way to turn")
    func blockedWithTurn() {
        var announcer = ObstacleAnnouncer()
        var blocked = PathAssessment.blocked
        blocked.turn = .right
        let events = run([object("wall", at: 1.8), object("wall", at: 1.8)], path: [blocked, blocked], announcer: &announcer)
        #expect(events[1].first?.text == "Wall ahead. Turn right.")
    }

    @Test("an obstacle at the corridor's edge is placed on its side")
    func sidePlacement() {
        var announcer = ObstacleAnnouncer()
        let chair = object("chair", at: 1.8, bearing: RelativeBearing(degrees: 20))
        let events = run([chair, chair], path: [.clear, .clear], announcer: &announcer)
        #expect(events[1].first?.text == "Chair ahead on your right. Keep left.")
    }

    // MARK: Eligibility and metadata

    @Test("objects beyond the outermost threshold, out of the path, or without a distance are ignored")
    func ignoresIneligible() {
        var announcer = ObstacleAnnouncer()
        let frame = [chair(at: 3.5), object(at: nil), chair(at: 1, inPath: false)]
        _ = announcer.announcements(for: frame, hazards: [], at: 0)
        #expect(announcer.announcements(for: frame, hazards: [], at: 0.1).isEmpty)
    }

    @Test("events expire quickly and carry a per-band dedup key")
    func eventMetadata() throws {
        var announcer = ObstacleAnnouncer()
        let now = Date(timeIntervalSinceReferenceDate: 0)
        _ = announcer.announcements(for: [chair(at: 1.5)], hazards: [], at: 0, now: now)
        let event = try #require(announcer.announcements(for: [chair(at: 1.5)], hazards: [], at: 0.1, now: now).first)

        #expect(event.expiresAt == now.addingTimeInterval(1.5))
        #expect(event.dedupKey == "path-chair-0-none")
        #expect(event.bearing == .ahead)
        #expect(event.category == .hazard && event.source == .obstacleDetection)
    }

    // MARK: Surface hazards

    @Test("a drop-off is at least high priority and announced once per band")
    func dropOff() throws {
        var announcer = ObstacleAnnouncer()
        let far = [ElevationHazard(type: .dropOff, distance: 2.3, heightChange: -0.4)]
        let frames = (0 ..< 4).map { announcer.announcements(for: [], hazards: far, at: Double($0) * 0.1) }

        // Three frames to confirm a surface hazard, one more than an object.
        #expect(frames.map(\.count) == [0, 0, 1, 0])
        let event = try #require(frames[2].first)
        #expect(event.priority == .high)
        #expect(event.text == "Drop-off ahead, 2.5 metres.")
        #expect(event.dedupKey == "surface-dropOff-0")
    }

    @Test("a drop-off within the stop band is a stop; a step is not")
    func hazardUrgency() {
        var announcer = ObstacleAnnouncer()
        let drop = [ElevationHazard(type: .dropOff, distance: 0.9, heightChange: -0.4)]
        _ = announcer.announcements(for: [], hazards: drop, at: 0)
        _ = announcer.announcements(for: [], hazards: drop, at: 0.1)
        let dropEvent = announcer.announcements(for: [], hazards: drop, at: 0.2).first
        #expect(dropEvent?.priority == .critical)
        #expect(dropEvent?.text == "Stop. Drop-off ahead.")

        var other = ObstacleAnnouncer()
        let step = [ElevationHazard(type: .stepDown, distance: 0.9, heightChange: -0.12)]
        _ = other.announcements(for: [], hazards: step, at: 0)
        _ = other.announcements(for: [], hazards: step, at: 0.1)
        let stepEvent = other.announcements(for: [], hazards: step, at: 0.2).first
        #expect(stepEvent?.priority == .high)
        #expect(stepEvent?.haptic == .attention)
        #expect(stepEvent?.text == "Step down ahead, 1 metre.")
    }

    @Test("a drop-off preempts an ordinary step when both confirm in one announcement cycle")
    func dropOffWinsHazardContention() {
        var announcer = ObstacleAnnouncer()
        // The nearer step is considered first, so this exercises the global admission gate:
        // the following drop-off must still be admitted as a higher-priority escalation.
        let hazards = [
            ElevationHazard(type: .stepDown, distance: 0.8, heightChange: -0.12),
            ElevationHazard(type: .dropOff, distance: 0.9, heightChange: -0.40),
        ]
        _ = announcer.announcements(for: [], hazards: hazards, at: 0)
        _ = announcer.announcements(for: [], hazards: hazards, at: 0.1)
        let events = announcer.announcements(for: [], hazards: hazards, at: 0.2)

        #expect(events.map(\.priority) == [.critical, .high])
        #expect(events.first?.text == "Stop. Drop-off ahead.")
    }

    @Test("a kerb that flickers is not announced again for the hazard repeat interval")
    func hazardFlicker() {
        var announcer = ObstacleAnnouncer()
        let kerb = [ElevationHazard(type: .stepUp, distance: 2.4, heightChange: 0.12)]
        var counts: [Int] = []
        for index in 0 ..< 15 {
            // Present for 1.5 s, gone for two, back again, over 7 s.
            let present = index < 3 || (6 ... 8).contains(index) || index >= 12
            counts.append(announcer.announcements(for: [], hazards: present ? kerb : [], at: Double(index) * 0.5).count)
        }
        #expect(counts == [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test("holes in depth coverage are not spoken")
    func unknownHazardsSilent() {
        var announcer = ObstacleAnnouncer()
        let hole = [ElevationHazard(type: .unknown, distance: 1.5, heightChange: 0)]
        let counts = (0 ..< 4).map { announcer.announcements(for: [], hazards: hole, at: Double($0) * 0.1).count }
        #expect(counts == [0, 0, 0, 0])
    }

    // MARK: The global gate

    @Test("two things at once are spaced out, one per minimum interval")
    func minimumInterval() {
        var announcer = ObstacleAnnouncer()
        let kerb = [ElevationHazard(type: .stepUp, distance: 2.4, heightChange: 0.12)]
        let counts = (0 ..< 7).map { index in
            announcer.announcements(for: [chair(at: 2.4)], hazards: kerb, at: Double(index) * 0.5).count
        }
        #expect(counts == [0, 1, 0, 0, 0, 0, 1])
    }

    @Test("an escalation is not held back by the minimum interval")
    func escalationBypassesGate() {
        var announcer = ObstacleAnnouncer()
        let events = run([chair(at: 2.4), chair(at: 2.4), chair(at: 1.1), chair(at: 1.1)], announcer: &announcer)
        #expect(events.map(\.count) == [0, 1, 0, 1])
    }
}
