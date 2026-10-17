#if DEBUG
import Foundation
import Testing
@testable import AccessAble

/// Reports fixed authorizations and samples, then finishes, so `LocationDebugViewModel.start()` returns.
private struct FixedLocationProvider: LocationProvider {
    var authorizations: [LocationAuthorization] = [.authorized(preciseAccuracy: true)]
    var samples: [LocationSample] = []

    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in
            for sample in samples {
                continuation.yield(sample)
            }
            continuation.finish()
        }
    }

    func headingSamples() -> AsyncStream<HeadingSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { continuation in
            for authorization in authorizations {
                continuation.yield(authorization)
            }
            continuation.finish()
        }
    }

    func requestAuthorization() async {}
}

private let fixTime = Date(timeIntervalSinceReferenceDate: 800_000_000)

private let fullSample = LocationSample(
    coordinate: GeoCoordinate(latitude: 33.777_123_4, longitude: -84.396_456_7),
    horizontalAccuracy: 4.5,
    timestamp: fixTime,
    speed: 1.3,
    speedAccuracy: 0.4,
    course: 90,
    courseAccuracy: 12.5
)

@MainActor
private func startedViewModel(_ provider: FixedLocationProvider) async -> LocationDebugViewModel {
    var services = AppServices.preview
    services.location = provider
    let viewModel = LocationDebugViewModel(services: services)
    await viewModel.start()
    return viewModel
}

@MainActor
private func field(_ label: String, in sample: LocationSample) throws -> LocationDebugViewModel.Field {
    try #require(LocationDebugViewModel.fields(of: sample).first { $0.label == label })
}

@MainActor
struct LocationDebugViewModelTests {
    @Test func formatsEveryField() throws {
        let time = fixTime.formatted(date: .omitted, time: .standard)

        #expect(LocationDebugViewModel.fields(of: fullSample) == [
            .init(label: "Time", value: time, spokenValue: time),
            .init(label: "Coordinate", value: "33.777123, -84.396457",
                  spokenValue: "latitude 33.777123, longitude -84.396457"),
            .init(label: "Horizontal accuracy", value: "4.5 m", spokenValue: "4.5 metres"),
            .init(label: "Speed", value: "1.3 m/s (4.7 km/h)",
                  spokenValue: "1.3 metres per second, 4.7 kilometres per hour"),
            .init(label: "Speed accuracy", value: "0.4 m/s", spokenValue: "0.4 metres per second"),
            .init(label: "Course", value: "90.0°", spokenValue: "90.0 degrees"),
            .init(label: "Course accuracy", value: "12.5°", spokenValue: "12.5 degrees"),
        ])
    }

    @Test(arguments: ["Speed", "Speed accuracy", "Course", "Course accuracy"])
    func missingMovementReadsUnavailable(_ label: String) throws {
        let sample = LocationSample(coordinate: fullSample.coordinate, horizontalAccuracy: 4.5, timestamp: fixTime)

        let missing = try field(label, in: sample)

        #expect(missing.value == "Unavailable")
        #expect(missing.spokenValue == "Unavailable")
    }

    @Test func spokenSummaryReadsEachFieldWithItsLabel() throws {
        let summary = LocationDebugViewModel.spokenSummary(of: fullSample)

        #expect(summary.contains("Speed, 1.3 metres per second, 4.7 kilometres per hour. Speed accuracy, "))
        #expect(summary.hasSuffix("Course accuracy, 12.5 degrees"))
    }

    @Test(arguments: [
        (3.7, "3 s", "3 seconds"),
        (1, "1 s", "1 second"),
        (0, "0 s", "0 seconds"),
        // a clock correction can put the reading slightly in the future
        (-2, "0 s", "0 seconds"),
    ])
    func ageOfLatestReading(secondsLater: Double, value: String, spokenValue: String) async {
        let viewModel = await startedViewModel(FixedLocationProvider(samples: [fullSample]))

        let age = viewModel.ageField(at: fixTime.addingTimeInterval(secondsLater))

        #expect(age == .init(label: "Age", value: value, spokenValue: spokenValue))
    }

    @Test func ageWithoutReadingsIsUnavailable() async {
        let viewModel = await startedViewModel(FixedLocationProvider())

        #expect(viewModel.latestSample == nil)
        #expect(viewModel.ageField(at: fixTime).value == "Unavailable")
    }

    @Test func keepsTheNewestReadingsFirst() async {
        let samples = (0..<25).map { index in
            LocationSample(coordinate: fullSample.coordinate, horizontalAccuracy: 5,
                           timestamp: fixTime.addingTimeInterval(Double(index)))
        }

        let viewModel = await startedViewModel(FixedLocationProvider(samples: samples))

        #expect(viewModel.sampleCount == 25)
        #expect(viewModel.countField.value == "25")
        #expect(viewModel.recentSamples == Array(samples.suffix(LocationDebugViewModel.historyLimit).reversed()))
        #expect(viewModel.latestSample == samples.last)
    }

    @Test func followsAuthorizationChanges() async {
        let viewModel = await startedViewModel(FixedLocationProvider(
            authorizations: [.notDetermined, .authorized(preciseAccuracy: false)]
        ))

        #expect(viewModel.authorization == .authorized(preciseAccuracy: false))
        #expect(viewModel.permissionField.value == "Allowed, approximate")
    }

    @Test(arguments: [
        (LocationAuthorization.notDetermined, "Not determined"),
        (.restricted, "Restricted"),
        (.denied, "Denied"),
        (.authorized(preciseAccuracy: true), "Allowed, precise"),
        (.authorized(preciseAccuracy: false), "Allowed, approximate"),
    ])
    func describesPermission(_ authorization: LocationAuthorization, expected: String) async {
        let viewModel = await startedViewModel(FixedLocationProvider(authorizations: [authorization]))

        #expect(viewModel.permissionField == .init(label: "Location access", value: expected, spokenValue: expected))
    }
}
#endif
