import Foundation
import Testing
@testable import AccessAble

struct RelativeDirectionTests {
    @Test(arguments: [
        (0.0, RelativeDirection.ahead), (45, .slightlyRight), (90, .right), (135, .behindRight), (180, .behind),
        (-180, .behind), (-135, .behindLeft), (-90, .left), (-45, .slightlyLeft),
    ])
    func eachSectorCentre(_ degrees: Double, _ expected: RelativeDirection) {
        #expect(RelativeDirection(RelativeBearing(degrees: degrees)) == expected)
    }

    @Test(arguments: [
        (22.4, RelativeDirection.ahead), (22.5, .slightlyRight), (67.4, .slightlyRight), (67.5, .right),
        (112.4, .right), (112.5, .behindRight), (157.4, .behindRight), (157.5, .behind),
        (-22.5, .ahead), (-22.6, .slightlyLeft), (-67.5, .slightlyLeft), (-67.6, .left),
        (-112.5, .left), (-112.6, .behindLeft), (-157.5, .behindLeft), (-157.6, .behind),
    ])
    func eachSectorHoldsItsAnticlockwiseEdge(_ degrees: Double, _ expected: RelativeDirection) {
        #expect(RelativeDirection(RelativeBearing(degrees: degrees)) == expected)
    }

    @Test(arguments: [(360.0, RelativeDirection.ahead), (-315, .slightlyRight), (270, .left)])
    func wrapsBearingsBeyondAHalfTurn(_ degrees: Double, _ expected: RelativeDirection) {
        #expect(RelativeDirection(RelativeBearing(degrees: degrees)) == expected)
    }

    @Test(arguments: [
        (RelativeDirection.ahead, "ahead"), (.slightlyRight, "slightly right"), (.right, "on your right"),
        (.behindRight, "behind you on your right"), (.behind, "behind you"), (.behindLeft, "behind you on your left"),
        (.left, "on your left"), (.slightlyLeft, "slightly left"),
    ])
    func eachPhrase(_ direction: RelativeDirection, _ phrase: String) {
        #expect(direction.phrase == phrase)
    }
}
