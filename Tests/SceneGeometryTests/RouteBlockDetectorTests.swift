import Testing
@testable import SceneGeometry

@Suite("Route blocked ahead")
struct RouteBlockDetectorTests {
    private func blocked(at distance: Float) -> PathAssessment {
        var path = PathAssessment.blocked
        path.blockedDistance = distance
        return path
    }

    /// The times at which the page opened, feeding `path` every half second up to `end`.
    private func openings(
        _ detector: inout RouteBlockDetector, _ path: PathAssessment?, from start: Double = 0, to end: Double
    ) -> [Double] {
        stride(from: start, through: end, by: 0.5).filter { detector.update(path, at: $0) }
    }

    @Test func opensOnlyAfterTheHold() {
        var detector = RouteBlockDetector()
        #expect(openings(&detector, blocked(at: 1), to: 3) == [3])
    }

    @Test func aClearFrameRestartsTheHold() {
        var detector = RouteBlockDetector()
        #expect(openings(&detector, blocked(at: 1), to: 2).isEmpty)
        #expect(openings(&detector, .clear, from: 2.5, to: 2.5).isEmpty)
        #expect(openings(&detector, blocked(at: 1), from: 3, to: 6) == [6])
    }

    @Test func aSidestepIsAWayRound() {
        var detector = RouteBlockDetector()
        let sidestep = PathAssessment(clearDirection: .left, sidestep: -0.8, blockedDistance: 1)
        #expect(openings(&detector, sidestep, to: 10).isEmpty)
    }

    @Test func farBlockagesAndUnknownPathsDontCount() {
        var detector = RouteBlockDetector()
        #expect(openings(&detector, blocked(at: 2.4), to: 10).isEmpty)
        #expect(openings(&detector, nil, from: 10.5, to: 20).isEmpty)
    }

    @Test func staysQuietAfterAnAnswer() {
        var detector = RouteBlockDetector()
        detector.dismiss(at: 0)
        #expect(openings(&detector, blocked(at: 1), to: 31) == [30])
    }

    @Test func showingCountsAsAnAnswer() {
        var detector = RouteBlockDetector()
        // Opens at 3, then the snooze holds it until 33.
        #expect(openings(&detector, blocked(at: 1), to: 36) == [3, 33])
    }
}
