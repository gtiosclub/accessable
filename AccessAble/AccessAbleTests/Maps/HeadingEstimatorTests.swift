import Foundation
import Testing
@testable import AccessAble

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func fix(speed: Double?, course: Double? = 212, courseAccuracy: Double? = 10, at seconds: Double = 0)
    -> LocationSample {
    LocationSample(coordinate: GeoCoordinate(latitude: 33.775, longitude: -84.399), horizontalAccuracy: 5,
                   timestamp: start.addingTimeInterval(seconds), speed: speed, course: course,
                   courseAccuracy: courseAccuracy)
}

private func compass(_ trueHeading: Double? = 87, magnetic: Double = 92, accuracy: Double = 15, at seconds: Double = 0)
    -> HeadingSample {
    HeadingSample(trueHeading: trueHeading, magneticHeading: magnetic, accuracy: accuracy,
                  timestamp: start.addingTimeInterval(seconds))
}

private func estimate(_ fixes: [LocationSample] = [], _ headings: [HeadingSample] = [], at seconds: Double = 0)
    -> UserHeading? {
    var estimator = HeadingEstimator()
    fixes.forEach { estimator.update(with: $0) }
    headings.forEach { estimator.update(with: $0) }
    return estimator.heading(at: start.addingTimeInterval(seconds))
}

struct HeadingEstimatorTests {
    @Test func walkingDirectionWinsWhileMoving() {
        #expect(estimate([fix(speed: 1.4)], [compass()])
            == UserHeading(degrees: 212, source: .walkingDirection, timestamp: start))
    }

    @Test func walkingDirectionStartsAtExactlyTheMinimumSpeed() {
        #expect(estimate([fix(speed: 0.7)], [compass()])?.source == .walkingDirection)
    }

    @Test func walkingDirectionWithoutCourseAccuracy() {
        #expect(estimate([fix(speed: 1.4, courseAccuracy: nil)])?.source == .walkingDirection)
    }

    @Test func movingWithoutCourseIsUnknownEvenWithAGoodCompass() {
        #expect(estimate([fix(speed: 1.4, course: nil)], [compass(accuracy: 5)]) == nil)
    }

    @Test func movingWithARoughCourseIsUnknown() {
        #expect(estimate([fix(speed: 1.4, courseAccuracy: 60)], [compass(accuracy: 5)]) == nil)
    }

    @Test func courseAccuracyOfExactly45IsUsable() {
        #expect(estimate([fix(speed: 1.4, courseAccuracy: 45)])?.source == .walkingDirection)
    }

    @Test(arguments: [nil, 0.0, 0.69])
    func standingStillUsesTheCompass(_ speed: Double?) {
        #expect(estimate([fix(speed: speed)], [compass()])
            == UserHeading(degrees: 87, source: .compass, timestamp: start))
    }

    @Test func compassAloneIsUsed() {
        #expect(estimate([], [compass()])?.source == .compass)
    }

    @Test(arguments: [(25.0, true), (26.0, false)])
    func compassAccuracyLimit(_ accuracy: Double, usable: Bool) {
        #expect((estimate([fix(speed: 0)], [compass(accuracy: accuracy)]) != nil) == usable)
    }

    @Test func missingTrueHeadingFallsBackToMagnetic() {
        #expect(estimate([], [compass(nil, magnetic: 92)])?.degrees == 92)
    }

    @Test func staleFixFallsBackToTheCompassRule() {
        let heading = estimate([fix(speed: 1.4, at: 0)], [compass(at: 3.5)], at: 3.5)

        #expect(heading == UserHeading(degrees: 87, source: .compass, timestamp: start.addingTimeInterval(3.5)))
    }

    @Test func staleFixWithoutCourseDoesNotBlockTheCompass() {
        #expect(estimate([fix(speed: 1.4, course: nil, at: 0)], [compass(at: 4)], at: 4)?.source == .compass)
    }

    @Test(arguments: [(3.0, true), (3.1, false)])
    func compassAgeLimit(_ seconds: Double, usable: Bool) {
        #expect((estimate([], [compass(at: 0)], at: seconds) != nil) == usable)
    }

    @Test func walkingDirectionAgeLimit() {
        #expect(estimate([fix(speed: 1.4)], at: 3)?.source == .walkingDirection)
        #expect(estimate([fix(speed: 1.4)], at: 3.1) == nil)
    }

    @Test func nothingReceivedIsUnknown() {
        #expect(estimate() == nil)
    }

    @Test func olderFixDoesNotReplaceANewerOne() {
        let heading = estimate([fix(speed: 1.4, course: 100, at: 2), fix(speed: 0, at: 1)], at: 2)

        #expect(heading?.degrees == 100)
    }

    @Test func olderCompassReadingDoesNotReplaceANewerOne() {
        #expect(estimate([], [compass(40, at: 2), compass(300, at: 1)], at: 2)?.degrees == 40)
    }

    @Test func newerSamplesReplaceOlderOnes() {
        #expect(estimate([fix(speed: 1.4, at: 1), fix(speed: 0, at: 2)], [compass(at: 2)], at: 2)?.source == .compass)
        #expect(estimate([], [compass(40, at: 1), compass(300, at: 2)], at: 2)?.degrees == 300)
    }

    @Test func nonFiniteFixIsIgnored() {
        #expect(estimate([fix(speed: 1.4, course: 100), fix(speed: 1.4, course: .nan, at: 1)], at: 1)?.degrees == 100)
    }

    @Test(arguments: [
        HeadingSample(trueHeading: .nan, magneticHeading: 92, accuracy: 15, timestamp: start),
        HeadingSample(trueHeading: 87, magneticHeading: .infinity, accuracy: 15, timestamp: start),
        HeadingSample(trueHeading: 87, magneticHeading: 92, accuracy: .nan, timestamp: start),
    ])
    func nonFiniteCompassReadingIsIgnored(_ sample: HeadingSample) {
        #expect(estimate([], [sample]) == nil)
    }
}
