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
