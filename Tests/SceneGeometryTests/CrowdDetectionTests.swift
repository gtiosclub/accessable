import CoreGraphics
import Foundation
import Testing
import simd

@testable import SceneGeometry

// T35 — grouping people into crowds, so a scene full of pedestrians is one sentence rather
// than one sentence each.
//
// The camera is at the world origin facing -Z, so a person at [0, 0, -4] is four metres
// straight ahead and +x is to their right. World Y is up, as `worldAlignment = .gravity`
// guarantees, which is what makes x/z the floor footprint.

private func person(at position: SIMD3<Float>, id: UUID = UUID()) -> Detection {
    let distance = Double(simd_length(position))
    let bearing = RelativeBearing(degrees: Double(atan2(position.x, -position.z)) * 180 / .pi)
    return Detection(
        id: id, label: "person", confidence: 0.9,
        boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.3),
        distance: distance, bearing: bearing,
        origin: .model, isHazard: false, worldPosition: position
    )
}

/// A tight knot of `count` people around `centre`, spaced well inside the link radius.
private func knot(count: Int, around centre: SIMD3<Float>) -> [Detection] {
    (0 ..< count).map { index in
        let offset = Float(index) * 0.7 - Float(count - 1) * 0.35
        return person(at: centre + SIMD3(offset, 0, Float(index % 2) * 0.3))
    }
}

@Suite("T35 — grouping people")
struct CrowdDetectorTests {
    @Test("people standing together become one group")
    func oneGroup() throws {
        let people = knot(count: 4, around: [0, 0, -3])
        let found = detectCrowds(among: people)
        let crowd = try #require(found.crowds.first)
        #expect(found.crowds.count == 1)
        #expect(crowd.count == 4)
        #expect(found.ungrouped.isEmpty)
        #expect(crowd.memberIDs == Set(people.map(\.id)))
        // The near edge is what the user reaches first, so that is what carries the distance.
        #expect(abs(crowd.nearestDistance - (people.compactMap(\.distance).min() ?? 0)) < 0.001)
    }

    @Test("two people are not a crowd and stay described individually")
    func twoIsNotACrowd() {
        let found = detectCrowds(among: knot(count: 2, around: [0, 0, -3]))
        #expect(found.crowds.isEmpty)
        #expect(found.ungrouped.count == 2)
    }

    @Test("two separate knots of people are two groups")
    func separateKnots() {
        let people = knot(count: 3, around: [0, 0, -3]) + knot(count: 3, around: [9, 0, -4])
        let found = detectCrowds(among: people)
        #expect(found.crowds.count == 2)
        #expect(found.ungrouped.isEmpty)
    }

    /// The chaining case. Six people spaced 1.5 m along the pavement all link to their
    /// neighbour, so single-link clustering alone would call them one group almost ten
    /// metres deep and announce its middle, where nobody is standing.
    @Test("a queue is split by depth instead of reported as one distant crowd")
    func queueIsSplit() throws {
        let people = (0 ..< 6).map { person(at: [0, 0, -2 - 1.5 * Float($0)]) }
        let found = detectCrowds(among: people)
        #expect(found.crowds.count == 2)
        for crowd in found.crowds {
            #expect(crowd.farthestDistance - crowd.nearestDistance <= CrowdTuning.default.maximumDepthSpan + 0.01)
        }
        // Nearest first, so the group being walked into is described first.
        let distances = found.crowds.map(\.nearestDistance)
        #expect(distances == distances.sorted())
    }

    @Test("a group spread sideways at one distance is left whole")
    func lateralSpreadStaysOneGroup() throws {
        // 1.8 m apart, inside the 2 m link radius, all four metres out.
        let people = [
            person(at: [-1.8, 0, -4]),
            person(at: [0, 0, -4]),
            person(at: [1.8, 0, -4]),
        ]
        let crowd = try #require(detectCrowds(among: people).crowds.first)
        #expect(crowd.count == 3)
        // Wide enough that one direction would misrepresent it, but all at one distance.
        #expect(crowd.isSpreadOut)
        #expect(!crowd.spansDistance)
    }

    @Test("people with nothing to cluster on are passed through, not dropped")
    func unplaceablePeopleAreUngrouped() {
        let noPosition = Detection(
            label: "person", confidence: 0.9,
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.3),
            distance: 3, bearing: .ahead, origin: .model, isHazard: false
        )
        let found = detectCrowds(among: knot(count: 3, around: [0, 0, -3]) + [noPosition])
        #expect(found.crowds.count == 1)
        #expect(found.ungrouped.map(\.id) == [noPosition.id])
    }

    @Test("people too far away to measure are not counted into a group")
    func beyondRangeIsUngrouped() {
        let found = detectCrowds(among: knot(count: 3, around: [0, 0, -30]))
        #expect(found.crowds.isEmpty)
        #expect(found.ungrouped.count == 3)
    }

    @Test("anything that is not a person is left alone")
    func nonPeopleUntouched() {
        let chair = Detection(
            label: "chair", confidence: 0.9,
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.3),
            distance: 2, bearing: .ahead, origin: .model, isHazard: true,
            worldPosition: [0, 0, -2]
        )
        let found = detectCrowds(among: knot(count: 3, around: [0, 0, -3]) + [chair])
        #expect(found.crowds.count == 1)
        #expect(found.ungrouped.map(\.id) == [chair.id])
    }

    @Test("no people at all is no crowd and no crash")
    func empty() {
        let found = detectCrowds(among: [])
        #expect(found.crowds.isEmpty)
        #expect(found.ungrouped.isEmpty)
    }
}

@Suite("T35 — how a crowd is spoken")
struct CrowdPhrasingTests {
    private func crowd(
        count: Int, nearest: Double, farthest: Double,
        bearing: Double = 0, span: ClosedRange<Double> = 0 ... 0
    ) -> CrowdRegion {
        CrowdRegion(
            count: count, nearestDistance: nearest, farthestDistance: farthest,
            bearing: RelativeBearing(degrees: bearing), bearingSpan: span,
            extent: 1, center: [0, 0, -Float(nearest)], memberIDs: []
        )
    }

    @Test("a small group is not given a false precision")
    func smallGroup() {
        // The detector's count is a floor on the real number, since people occlude; three
        // or four is "a few" rather than a figure read out as fact.
        #expect(SpokenPhrasing.describe(crowd(count: 3, nearest: 3, farthest: 3)) == "A few people 3 metres ahead.")
    }

    @Test("a middling group gets an approximate count")
    func middlingGroup() {
        #expect(SpokenPhrasing.describe(crowd(count: 6, nearest: 4, farthest: 4)) == "About 6 people 4 metres ahead.")
    }

    @Test("a big group is not counted at all")
    func largeGroup() {
        #expect(SpokenPhrasing.describe(crowd(count: 14, nearest: 5, farthest: 5)) == "A large group 5 metres ahead.")
    }

    @Test("a group running away from the user is given as a range")
    func deepGroup() {
        let text = SpokenPhrasing.describe(crowd(count: 6, nearest: 2, farthest: 5))
        #expect(text == "About 6 people, 2 metres to 5 metres ahead.")
    }

    @Test("a wide group says so")
    func spreadGroup() {
        let text = SpokenPhrasing.describe(crowd(count: 6, nearest: 4, farthest: 4, span: -30 ... 30))
        #expect(text == "About 6 people 4 metres ahead, spread out.")
    }

    @Test("a group off to one side is placed there")
    func sideGroup() {
        let text = SpokenPhrasing.describe(crowd(count: 3, nearest: 3, farthest: 3, bearing: 60))
        #expect(text == "A few people on your right, 3 metres.")
    }
}

@Suite("T35 — describing a scene with a crowd in it")
struct CrowdDescriptionTests {
    /// The acceptance case. Before T35 the four-sentence budget went entirely on "Person …"
    /// and the chair and the sign were never said.
    @Test("one crowd sentence leaves room for the rest of the scene")
    func crowdFreesTheBudget() {
        let chair = Detection(
            label: "chair", confidence: 0.9,
            boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.1, height: 0.3),
            distance: 1.5, bearing: .ahead, origin: .model, isHazard: true,
            worldPosition: [0, 0, -1.5]
        )
        let observation = SceneObservation(
            detections: knot(count: 6, around: [0, 0, -4]) + [chair],
            recognizedText: [RecognizedText(
                string: "Exit", confidence: 0.9,
                boundingBox: CGRect(x: 0.7, y: 0.2, width: 0.2, height: 0.1)
            )]
        )

        let text = SceneDescriptionBuilder().describe(observation)
        #expect(text.contains("Chair"))
        // One mention of the group, not six.
        #expect(text.contains("About 6 people"))
        #expect(!text.contains("Person"))
        // And the sign survives, which is the point.
        #expect(text.contains("Exit"))
    }

    @Test("two people are still described one by one")
    func twoPeopleStillNamed() {
        let observation = SceneObservation(detections: knot(count: 2, around: [0, 0, -3]))
        let text = SceneDescriptionBuilder().describe(observation)
        #expect(text.contains("Person"))
        #expect(!text.contains("people"))
    }
}

@Suite("T35 — when a crowd is mentioned unprompted")
struct CrowdAnnouncerTests {
    private func crowd(nearest: Double, bearing: Double = 0, count: Int = 5) -> CrowdRegion {
        CrowdRegion(
            count: count, nearestDistance: nearest, farthestDistance: nearest,
            bearing: RelativeBearing(degrees: bearing), bearingSpan: 0 ... 0,
            extent: 1, center: [0, 0, -Float(nearest)], memberIDs: []
        )
    }

    @Test("a crowd appearing ahead is mentioned once")
    func firstSighting() throws {
        var announcer = CrowdAnnouncer()
        let events = announcer.announcements(for: [crowd(nearest: 5)], at: 0)
        let event = try #require(events.first)
        // Ambient, so a user who wants no commentary can switch it off without losing a
        // safety warning.
        #expect(event.category == .ambient)
        #expect(event.priority == .normal)
    }

    @Test("standing in front of the same crowd stays silent")
    func noRepeat() {
        var announcer = CrowdAnnouncer()
        _ = announcer.announcements(for: [crowd(nearest: 5)], at: 0)
        for step in 1 ... 60 {
            let events = announcer.announcements(for: [crowd(nearest: 5)], at: Double(step) * 0.2)
            #expect(events.isEmpty)
        }
    }

    @Test("a crowd off to the side is not worth saying")
    func sideCrowdIgnored() {
        var announcer = CrowdAnnouncer()
        #expect(announcer.announcements(for: [crowd(nearest: 5, bearing: 70)], at: 0).isEmpty)
    }

    @Test("a crowd far down the street is not worth saying")
    func distantCrowdIgnored() {
        var announcer = CrowdAnnouncer()
        #expect(announcer.announcements(for: [crowd(nearest: 11)], at: 0).isEmpty)
    }

    @Test("meeting a crowd again after it has gone is news")
    func reappearanceIsNews() throws {
        var announcer = CrowdAnnouncer()
        _ = announcer.announcements(for: [crowd(nearest: 5)], at: 0)
        // Gone for longer than clearAfter.
        for step in 1 ... 30 {
            _ = announcer.announcements(for: [], at: Double(step) * 0.2)
        }
        let events = announcer.announcements(for: [crowd(nearest: 5)], at: 10)
        #expect(events.count == 1)
    }
}
