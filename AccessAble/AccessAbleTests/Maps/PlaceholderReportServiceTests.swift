import Foundation
import Testing
@testable import AccessAble

struct PlaceholderReportServiceTests {
    private let coordinate = GeoCoordinate(
        latitude: 33.7756,
        longitude: -84.3963
    )

    /// One stored report from one captured date, so every read of it is equal.
    private let sample: Report

    init() {
        let createdAt = Date.now
        sample = Report(
            id: "r1",
            kind: .construction,
            coordinate: coordinate,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(3600),
            reporterID: "test-user"
        )
    }

    @Test
    func storesAndFindsNearbyReport() async throws {
        let service = PlaceholderReportService()
        try await service.submit(sample)

        let actual = try await service.reports(near: coordinate, radius: 100)
        #expect(actual == [sample])
    }

    @Test
    func publishesNewReportsToLiveStream() async throws {
        let service = PlaceholderReportService()
        var iterator = service.reportChanges(
            near: coordinate,
            radius: 100
        ).makeAsyncIterator()

        #expect(await iterator.next() == [])
        try await service.submit(sample)
        #expect(await iterator.next() == [sample])
    }
}
