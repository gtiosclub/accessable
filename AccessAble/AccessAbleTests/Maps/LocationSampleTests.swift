import CoreLocation
import Testing
@testable import AccessAble

private let fixCoordinate = CLLocationCoordinate2D(latitude: 33.777_123_456_789, longitude: -84.396_456_789_012)
private let fixTime = Date(timeIntervalSinceReferenceDate: 800_000_000.123_456)

private func location(
    horizontalAccuracy: Double = 5,
    course: Double = 90,
    courseAccuracy: Double = 10,
    speed: Double = 1.4,
    speedAccuracy: Double = 0.5
) -> CLLocation {
    CLLocation(
        coordinate: fixCoordinate,
        altitude: 290,
        horizontalAccuracy: horizontalAccuracy,
        verticalAccuracy: 8,
        course: course,
        courseAccuracy: courseAccuracy,
        speed: speed,
        speedAccuracy: speedAccuracy,
        timestamp: fixTime
    )
}

struct LocationSampleTests {
    @Test func copiesEveryValidReading() throws {
        let sample = try #require(LocationSample(location()))

        #expect(sample == LocationSample(
            coordinate: GeoCoordinate(fixCoordinate),
            horizontalAccuracy: 5,
            timestamp: fixTime,
            speed: 1.4,
            speedAccuracy: 0.5,
            course: 90,
            courseAccuracy: 10
        ))
    }

    @Test func copiesCoordinateAndTimestampExactly() throws {
        let sample = try #require(LocationSample(location()))

        #expect(sample.coordinate.latitude == fixCoordinate.latitude)
        #expect(sample.coordinate.longitude == fixCoordinate.longitude)
        #expect(sample.timestamp == fixTime)
    }

    @Test func invalidSpeedIsDropped() throws {
        let sample = try #require(LocationSample(location(speed: -1)))

        #expect(sample.speed == nil)
        #expect(sample.speedAccuracy == 0.5)
        #expect(sample.course == 90)
        #expect(sample.courseAccuracy == 10)
    }

    // the simulator and GPX playback report real speed with no accuracy
    @Test func speedWithoutAccuracyIsKept() throws {
        let sample = try #require(LocationSample(location(speedAccuracy: -1)))

        #expect(sample.speed == 1.4)
        #expect(sample.speedAccuracy == nil)
        #expect(sample.course == 90)
        #expect(sample.courseAccuracy == 10)
    }

    @Test func invalidCourseIsDropped() throws {
        let sample = try #require(LocationSample(location(course: -1)))

        #expect(sample.course == nil)
        #expect(sample.courseAccuracy == 10)
        #expect(sample.speed == 1.4)
        #expect(sample.speedAccuracy == 0.5)
    }

    // the simulator and GPX playback report real course with no accuracy
    @Test func courseWithoutAccuracyIsKept() throws {
        let sample = try #require(LocationSample(location(courseAccuracy: -1)))

        #expect(sample.course == 90)
        #expect(sample.courseAccuracy == nil)
        #expect(sample.speed == 1.4)
        #expect(sample.speedAccuracy == 0.5)
    }
}
