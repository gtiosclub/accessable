import CoreGraphics
import Foundation
import Testing
@testable import SceneGeometry

@Suite("Danger levels and the user's alert filter")
struct AlertFilterTests {
    private func detection(_ label: String) -> Detection {
        Detection(label: label, confidence: 0.9, boundingBox: .zero, origin: .model, isHazard: true)
    }

    @Test("vehicles are critical, furniture medium, things on a table low")
    func levels() {
        #expect(DangerLevel(of: detection("car")) == .critical)
        #expect(DangerLevel(of: detection("fire hydrant")) == .high)
        #expect(DangerLevel(of: detection("chair")) == .medium)
        #expect(DangerLevel(of: detection("laptop")) == .low)
    }

    @Test("an unnamed obstacle or unknown label counts as high: it could be a pole")
    func unknownIsHigh() {
        #expect(DangerLevel(of: detection(Detection.obstacleLabel)) == .high)
        #expect(DangerLevel(of: detection("lamp post")) == .high)
    }

    @Test("drop-offs and steps down are critical; approaching people medium, vehicles critical")
    func hazardAndApproachLevels() {
        #expect(DangerLevel(of: ElevationHazardType.dropOff) == .critical)
        #expect(DangerLevel(of: ElevationHazardType.stepUp) == .high)
        #expect(DangerLevel(approaching: "person") == .medium)
        #expect(DangerLevel(approaching: "Bicycle") == .critical)
    }

    @Test("the filter lets through its own level and above")
    func allows() {
        let filter = AlertFilter(minimumDanger: .high, maximumDistance: 2.5)
        #expect(filter.allows(.critical) && filter.allows(.high))
        #expect(!filter.allows(.medium))
    }
}

@Suite("Obstacle announcements under the user's alert filter")
struct FilteredObstacleAnnouncerTests {
    private func object(_ label: String, at distance: Double) -> ObstacleAlertInput {
        ObstacleAlertInput(
            detection: Detection(
                trackID: UUID(), label: label, confidence: 0.9,
                boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
                distance: distance, bearing: .ahead, origin: .geometric, isHazard: true
            ),
            isInPath: true
        )
    }

    private func announcer(_ danger: DangerLevel = .medium, within distance: Float = 2.5) -> ObstacleAnnouncer {
        var announcer = ObstacleAnnouncer()
        announcer.alertFilter = AlertFilter(minimumDanger: danger, maximumDistance: distance)
        return announcer
    }

    private func run(_ frames: [ObstacleAlertInput], announcer: inout ObstacleAnnouncer) -> [[AnnouncementEvent]] {
        frames.enumerated().map { index, frame in
            announcer.announcements(for: [frame], hazards: [], at: Double(index) * 0.1)
        }
    }

    @Test("something below the danger bar is not announced at warning distance")
    func belowBarIsQuiet() {
        var announcer = announcer(.high)
        let events = run(Array(repeating: object("chair", at: 2), count: 4), announcer: &announcer)
        #expect(events.allSatisfy { $0.isEmpty })
    }

    @Test("below the bar, it still gets a Stop inside the stop distance")
    func stopIsNeverFiltered() {
        var announcer = announcer(.critical)
        let events = run(Array(repeating: object("laptop", at: 1), count: 3), announcer: &announcer)
        #expect(events.flatMap { $0 }.map(\.text) == ["Stop. Laptop ahead."])
    }

    @Test("the user's distance moves the first warning out, and the stop distance stays")
    func distanceSetsFirstBand() {
        var far = announcer(within: 4)
        let farEvents = run([object("chair", at: 3.5), object("chair", at: 3.5)], announcer: &far)
        #expect(farEvents[1].first?.priority == .high)

        var near = announcer(within: 1.5)
        let nearEvents = run(Array(repeating: object("chair", at: 2), count: 3), announcer: &near)
        #expect(nearEvents.allSatisfy { $0.isEmpty })
    }

    @Test("a map blockage made only of filtered-out things is treated as clear")
    func filteredBlockage() {
        var announcer = announcer(.high)
        let laptop = [object("laptop", at: 2)]
        let events = (0 ..< 4).map {
            announcer.announcements(
                for: laptop, hazards: [], blockedAhead: BlockedAhead(distance: 2), at: Double($0) * 0.1
            )
        }
        #expect(events.allSatisfy { $0.isEmpty })
    }

    @Test("a drop-off is announced whatever the bar, at the default distance")
    func dropOffAlwaysWarns() {
        var announcer = announcer(.critical, within: 1.5)
        let drop = [ElevationHazard(type: .dropOff, distance: 2.3, heightChange: -0.4)]
        let events = (0 ..< 4).flatMap { announcer.announcements(for: [], hazards: drop, at: Double($0) * 0.1) }
        #expect(events.count == 1)
    }

    @Test("a step up below the bar is left out")
    func stepUpFiltered() {
        var announcer = announcer(.critical)
        let step = [ElevationHazard(type: .stepUp, distance: 2, heightChange: 0.12)]
        let events = (0 ..< 5).flatMap { announcer.announcements(for: [], hazards: step, at: Double($0) * 0.1) }
        #expect(events.isEmpty)
    }
}

@Suite("Keeping the camera from talking too much")
struct QuieterAnnouncementTests {
    private func chair(at distance: Double) -> ObstacleAlertInput {
        ObstacleAlertInput(
            detection: Detection(
                trackID: UUID(), label: "chair", confidence: 0.9,
                boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
                distance: distance, bearing: .ahead, origin: .geometric, isHazard: true
            ),
            isInPath: true
        )
    }

    @Test("a second chair soon after the first is a buzz, not a sentence")
    func repeatedKindIsHapticOnly() {
        var announcer = ObstacleAnnouncer()
        var spoken: [AnnouncementEvent] = []
        // One chair, then the path clears for 6 s, then another chair.
        for step in 0 ..< 3 { spoken += announcer.announcements(for: [chair(at: 2)], hazards: [], at: Double(step) * 0.1) }
        for step in 3 ..< 60 { spoken += announcer.announcements(for: [], hazards: [], at: Double(step) * 0.1) }
        for step in 60 ..< 63 { spoken += announcer.announcements(for: [chair(at: 2)], hazards: [], at: Double(step) * 0.1) }
        #expect(spoken.map(\.hapticOnly) == [false, true])
        #expect(spoken.allSatisfy { $0.haptic != nil })
    }

    @Test("a Stop is never haptic-only")
    func stopIsSpoken() {
        var announcer = ObstacleAnnouncer()
        var events: [AnnouncementEvent] = []
        for step in 0 ..< 3 { events += announcer.announcements(for: [chair(at: 1)], hazards: [], at: Double(step) * 0.1) }
        for step in 3 ..< 60 { events += announcer.announcements(for: [], hazards: [], at: Double(step) * 0.1) }
        for step in 60 ..< 63 { events += announcer.announcements(for: [chair(at: 1)], hazards: [], at: Double(step) * 0.1) }
        #expect(events.filter { $0.priority == .critical }.allSatisfy { !$0.hapticOnly })
    }

    @Test("a persisting Stop is not repeated to someone standing still")
    func noReminderWhenStill() {
        var announcer = ObstacleAnnouncer()
        let events = (0 ..< 12).map {
            announcer.announcements(for: [chair(at: 0.8)], hazards: [], at: Double($0), isUserMoving: false)
        }
        #expect(events.map(\.count) == [0, 1] + Array(repeating: 0, count: 10))
    }

    @Test("a person approaching is only announced once it is urgent")
    func peopleOnlyWhenUrgent() {
        var announcer = ApproachAnnouncer()
        let id = UUID()
        let walking = ApproachThreat(
            trackID: id, label: "person", timeToApproach: 2.5, missDistance: 0.2,
            distance: 3, bearing: .ahead, speed: 1.2
        )
        #expect(announcer.announcements(for: [walking], at: 0).isEmpty)
        #expect(announcer.announcements(for: [walking], at: 0.1).isEmpty)
        let close = ApproachThreat(
            trackID: id, label: "person", timeToApproach: 1, missDistance: 0.2,
            distance: 1.2, bearing: .ahead, speed: 1.2
        )
        #expect(announcer.announcements(for: [close], at: 0.2).first?.priority == .critical)
    }

    @Test("the danger bar silences a non-urgent approach below it")
    func approachBelowBar() {
        var announcer = ApproachAnnouncer()
        announcer.urgentOnlyLabels = []
        announcer.alertFilter = AlertFilter(minimumDanger: .high, maximumDistance: 2.5)
        let id = UUID()
        let dog = ApproachThreat(
            trackID: id, label: "dog", timeToApproach: 2.5, missDistance: 0.2,
            distance: 3, bearing: .ahead, speed: 1.2
        )
        _ = announcer.announcements(for: [dog], at: 0)
        #expect(announcer.announcements(for: [dog], at: 0.1).isEmpty)
    }
}

@Suite("The shared speech budget")
struct SpeechBudgetTests {
    private func event(_ priority: AnnouncementPriority, hapticOnly: Bool = false, _ text: String = "x") -> AnnouncementEvent {
        AnnouncementEvent(
            category: .hazard, priority: priority, text: text, haptic: .obstacleNear,
            source: .obstacleDetection, hapticOnly: hapticOnly
        )
    }

    @Test("one event per frame: the most urgent, first of equals")
    func oneMostUrgent() {
        var budget = SpeechBudget()
        let admitted = budget.admit([event(.normal, "crowd"), event(.high, "chair"), event(.high, "car")], at: 0)
        #expect(admitted.map(\.text) == ["chair"])
    }

    @Test("nothing as urgent is spoken within the gap; more urgent and Stop are")
    func gap() {
        var budget = SpeechBudget()
        #expect(budget.admit([event(.normal)], at: 0).count == 1)
        #expect(budget.admit([event(.normal)], at: 1).isEmpty)
        #expect(budget.admit([event(.high)], at: 1.5).count == 1)
        #expect(budget.admit([event(.high)], at: 2).isEmpty)
        #expect(budget.admit([event(.critical)], at: 2.1).count == 1)
        #expect(budget.admit([event(.critical)], at: 2.2).count == 1)
        #expect(budget.admit([event(.normal)], at: 5.3).count == 1)
    }

    @Test("haptic-only events pass without using up the gap")
    func hapticOnlyIsFree() {
        var budget = SpeechBudget()
        #expect(budget.admit([event(.high, hapticOnly: true)], at: 0).count == 1)
        #expect(budget.admit([event(.normal)], at: 0.5).count == 1)
        // Spoken one rejected inside the gap: the buzz still goes.
        let admitted = budget.admit([event(.normal), event(.high, hapticOnly: true, "buzz")], at: 1)
        #expect(admitted.map(\.text) == ["buzz"])
    }
}

@Suite("What the screen shows matches what the voice decided")
struct PathWarningTests {
    private func object(_ label: String, at distance: Double, track: UUID = UUID()) -> ObstacleAlertInput {
        ObstacleAlertInput(
            detection: Detection(
                trackID: track, label: label, confidence: 0.9,
                boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
                distance: distance, bearing: .ahead, origin: .geometric, isHazard: true
            ),
            isInPath: true
        )
    }

    @Test("a confirmed warning carries its name, distance, track and advice")
    func warningMirrorsVoice() throws {
        var announcer = ObstacleAnnouncer()
        let track = UUID()
        let left = PathAssessment(clearDirection: .left, sidestep: -0.7)
        _ = announcer.announcements(for: [object("chair", at: 2, track: track)], hazards: [], path: left, at: 0)
        #expect(announcer.currentWarning == nil)  // not confirmed yet
        _ = announcer.announcements(for: [object("chair", at: 2, track: track)], hazards: [], path: left, at: 0.1)
        let warning = try #require(announcer.currentWarning)
        #expect(warning == PathWarning(
            name: "Chair", distance: 2, isStop: false, advice: "One step left", trackID: track, side: .left, offset: -0.7
        ))
    }

    @Test("an unnamed blockage from the map is a warning too, with nothing to outline")
    func mapBlockage() throws {
        var announcer = ObstacleAnnouncer()
        for step in 0 ..< 2 {
            _ = announcer.announcements(for: [], hazards: [], blockedAhead: BlockedAhead(distance: 1), at: Double(step) * 0.1)
        }
        let warning = try #require(announcer.currentWarning)
        #expect(warning.isStop && warning.name == "Obstacle" && warning.trackID == nil)
    }

    @Test("a stop beats a nearer-looking but calmer hazard, and the warning clears with the path")
    func stopWinsThenClears() {
        var announcer = ObstacleAnnouncer()
        let step = [ElevationHazard(type: .stepUp, distance: 2, heightChange: 0.12)]
        for frame in 0 ..< 3 {
            _ = announcer.announcements(for: [object("chair", at: 1)], hazards: step, at: Double(frame) * 0.1)
        }
        #expect(announcer.currentWarning?.isStop == true)
        #expect(announcer.currentWarning?.name == "Chair")
        for frame in 3 ..< 30 {
            _ = announcer.announcements(for: [], hazards: [], at: Double(frame) * 0.1)
        }
        #expect(announcer.currentWarning == nil)
    }
}

@Suite("How far left or right")
struct PreciseAdviceTests {
    @Test("a sidestep is counted in steps of half a metre, up to three")
    func steps() {
        #expect(SpokenPhrasing.sidestep(0.3, ahead: 2, side: "right") == "One step right.")
        #expect(SpokenPhrasing.sidestep(-1.0, ahead: 2, side: "left") == "Two steps left.")
        #expect(SpokenPhrasing.sidestep(1.4, ahead: 2, side: "right") == "Three steps right.")
    }

    @Test("farther to the side, it is a clock direction instead")
    func clock() {
        // 2 m across at 2 m ahead is 45 degrees: between 1 and 2 o'clock, rounds to 2.
        #expect(SpokenPhrasing.sidestep(2, ahead: 2, side: "right") == "Bear right, 2 o'clock.")
        #expect(SpokenPhrasing.sidestep(-2, ahead: 4, side: "left") == "Bear left, 11 o'clock.")
    }

    @Test("without a measured offset it says only which way")
    func noOffset() {
        #expect(SpokenPhrasing.sidestep(nil, ahead: 2, side: "left") == "Go left.")
    }

    @Test("Stop gives the instruction, not the name")
    func shortStop() {
        let chair = Detection(label: "chair", confidence: 0.9, boundingBox: .zero, bearing: .ahead, origin: .model, isHazard: true)
        let right = PathAssessment(clearDirection: .right, sidestep: 0.5)
        #expect(SpokenPhrasing.guidance(for: chair, priority: .critical, path: right) == "Stop. One step right.")
        #expect(SpokenPhrasing.guidance(for: chair, priority: .critical, path: nil) == "Stop. Chair ahead.")
    }
}

@Suite("Telling the user when they have gone far enough")
struct StraightAheadTests {
    private func chair(at distance: Double) -> ObstacleAlertInput {
        ObstacleAlertInput(
            detection: Detection(
                trackID: UUID(), label: "chair", confidence: 0.9,
                boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
                distance: distance, bearing: .ahead, origin: .geometric, isHazard: true
            ),
            isInPath: true
        )
    }

    @Test("after 'One step right', an emptied corridor says 'Straight ahead now', soon and once")
    func straightAhead() throws {
        var announcer = ObstacleAnnouncer()
        let right = PathAssessment(clearDirection: .right, sidestep: 0.5)
        var events: [[AnnouncementEvent]] = []
        for frame in 0 ..< 2 {
            events.append(announcer.announcements(for: [chair(at: 2)], hazards: [], path: right, at: Double(frame) * 0.1))
        }
        #expect(events[1].first?.text == "Chair ahead. One step right.")
        // The user steps right; the chair leaves the corridor. 0.5 s later, well inside
        // the 2.5 s gap since the instruction, the answer comes.
        for frame in 2 ..< 12 {
            events.append(announcer.announcements(for: [], hazards: [], path: .clear, at: Double(frame) * 0.1))
        }
        let spoken = events.flatMap { $0 }.map(\.text)
        #expect(spoken == ["Chair ahead. One step right.", "Straight ahead now."])
        let answer = try #require(events.flatMap { $0 }.last)
        #expect(answer.dedupKey == ObstacleAnnouncer.straightAheadKey)
    }

    @Test("the shared speech budget lets the answer through right after the instruction")
    func budgetLetsItThrough() {
        var budget = SpeechBudget()
        let instruction = AnnouncementEvent(category: .hazard, priority: .high, text: "Chair ahead. One step right.", source: .obstacleDetection)
        let answer = AnnouncementEvent(
            category: .hazard, priority: .high, text: "Straight ahead now.", source: .obstacleDetection,
            dedupKey: ObstacleAnnouncer.straightAheadKey
        )
        #expect(budget.admit([instruction], at: 0).count == 1)
        #expect(budget.admit([answer], at: 1).count == 1)
    }

    @Test("a warning with no direction still ends with 'Path clear', not 'Straight ahead now'")
    func plainClear() {
        var announcer = ObstacleAnnouncer()
        var spoken: [String] = []
        for frame in 0 ..< 3 {
            spoken += announcer.announcements(for: [chair(at: 1)], hazards: [], at: Double(frame) * 0.1).map(\.text)
        }
        for frame in 3 ..< 40 {
            spoken += announcer.announcements(for: [], hazards: [], at: Double(frame) * 0.1).map(\.text)
        }
        #expect(spoken == ["Stop. Chair ahead.", "Path clear."])
    }
}

@Suite("Steering by ear and by feel")
struct SteeringTests {
    private func warning(side: TurnSide?, offset: Float?, distance: Double = 2) -> PathWarning {
        PathWarning(name: "Chair", distance: distance, isStop: false, advice: nil, trackID: nil, side: side, offset: offset)
    }

    @Test("the beep comes from the side to move towards, harder over for a bigger sidestep")
    func side() throws {
        let small = try #require(SteeringCue(warning: warning(side: .right, offset: 0.5)))
        let big = try #require(SteeringCue(warning: warning(side: .left, offset: -1.5)))
        #expect(small.side > 0 && small.side < big.side.magnitude)
        #expect(big.side == -1)
        #expect(big.interval < small.interval)
    }

    @Test("closer is more urgent; no direction means no beep")
    func urgency() throws {
        let far = try #require(SteeringCue(warning: warning(side: .right, offset: 0.5, distance: 2.5)))
        let near = try #require(SteeringCue(warning: warning(side: .right, offset: 0.5, distance: 1.2)))
        #expect(far.urgency == 0 && near.urgency == 1)
        #expect(SteeringCue(warning: warning(side: nil, offset: nil)) == nil)
        #expect(SteeringCue(warning: nil) == nil)
    }

    @Test("a warning with a way round buzzes the turn pattern for that side")
    func directionalHaptic() throws {
        var announcer = ObstacleAnnouncer()
        let left = PathAssessment(clearDirection: .left, sidestep: -0.5)
        let chair = ObstacleAlertInput(
            detection: Detection(
                trackID: UUID(), label: "chair", confidence: 0.9, boundingBox: .zero,
                distance: 2, bearing: .ahead, origin: .geometric, isHazard: true
            ),
            isInPath: true
        )
        _ = announcer.announcements(for: [chair], hazards: [], path: left, at: 0)
        let event = try #require(announcer.announcements(for: [chair], hazards: [], path: left, at: 0.1).first)
        #expect(event.haptic == .turnLeft)
        #expect(announcer.currentWarning?.offset == -0.5)
    }
}
