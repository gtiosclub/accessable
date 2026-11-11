import Foundation
import Testing
@testable import AccessAble

private let time = Date(timeIntervalSince1970: 1_700_000_000)

private func door(_ key: String = "door-1", degrees: Double? = 20, distance: Double? = 5,
                  accuracy: DistanceAccuracy? = .measured, confidence: Float = 0.9) -> LandmarkObservation {
    LandmarkObservation(kind: .entrance, key: key, bearing: degrees.map { RelativeBearing(degrees: $0) },
                        distance: distance, distanceAccuracy: distance == nil ? nil : accuracy, confidence: confidence)
}

struct EntranceGuideTests {
    @Test(arguments: [
        (0.0, "Entrance ahead, 5 metres."),
        (20.0, "Entrance slightly right, 5 metres."),
        (-60.0, "Entrance on your left, 5 metres."),
        (170.0, "Entrance behind you, 5 metres."),
    ])
    func doorIsGivenWithItsDirectionAndDistance(degrees: Double, text: String) {
        #expect(EntranceGuide.text(for: door(degrees: degrees)) == text)
    }

    @Test
    func estimatedDistanceIsHedgedAndMissingDepthGivesNoDirection() {
        #expect(EntranceGuide.text(for: door(accuracy: .estimated(plusMinus: 1)))
            == "Entrance slightly right, about 5 metres.")
        #expect(EntranceGuide.text(for: door(distance: nil)) == "Entrance slightly right.")
        #expect(EntranceGuide.text(for: door(degrees: nil, distance: nil)) == "Entrance in view.")
    }

    @Test(arguments: [(30.1, false, false), (30.0, false, true), (200.0, true, true)])
    func onlyNearTheEndOrAfterArriving(remaining: Double, hasArrived: Bool, speaks: Bool) {
        var guide = EntranceGuide()

        #expect((guide.guidance(for: door(), remaining: remaining, hasArrived: hasArrived, at: time) != nil) == speaks)
    }

    @Test
    func eachDoorOnceAndDoorsSpacedOut() {
        var guide = EntranceGuide()

        #expect(guide.guidance(for: door("a"), remaining: 10, hasArrived: false, at: time) != nil)
        #expect(guide.guidance(for: door("a"), remaining: 10, hasArrived: false, at: time + 60) == nil)
        #expect(guide.guidance(for: door("b"), remaining: 10, hasArrived: false, at: time + 7.9) == nil)
        #expect(guide.guidance(for: door("b"), remaining: 10, hasArrived: false, at: time + 8) != nil)
    }

    @Test
    func farDoorsWeakReadsAndOtherKindsAreIgnored() {
        var guide = EntranceGuide()
        let stairs = LandmarkObservation(kind: .stairs, key: "s", bearing: .ahead, distance: 3, confidence: 0.9)

        #expect(guide.guidance(for: door(distance: 25.1), remaining: 10, hasArrived: false, at: time) == nil)
        #expect(guide.guidance(for: door(confidence: 0.49), remaining: 10, hasArrived: false, at: time) == nil)
        #expect(guide.guidance(for: stairs, remaining: 10, hasArrived: false, at: time) == nil)
        // none of those used up the spacing
        #expect(guide.guidance(for: door(distance: 25), remaining: 10, hasArrived: false, at: time) != nil)
    }
}
