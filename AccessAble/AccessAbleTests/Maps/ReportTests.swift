import Foundation
import Testing
@testable import AccessAble

struct ReportTests {
    private let report = Report(
        id: "r1", kind: .blockedPath,
        coordinate: GeoCoordinate(latitude: 33.7756, longitude: -84.3963),
        createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 86_400),
        reporterID: "user-1"
    )

    /// `firebase/firestore.rules` rejects a report with any other field name.
    @Test
    func encodesTheFieldNamesTheRulesRequire() throws {
        let data = try JSONEncoder().encode(report)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(fields.keys) == [
            "id", "kind", "coordinate", "createdAt", "expiresAt", "confirmations", "reporterID",
            "negativeConfirmations", "isRemoved", "confirmationResponses"
        ])
        #expect(fields["kind"] as? String == "blockedPath")
        #expect(fields["confirmations"] as? Int == 0)
        #expect(fields["negativeConfirmations"] as? Int == 0)
        #expect(fields["isRemoved"] as? Bool == false)
        #expect((fields["confirmationResponses"] as? [String: Bool])?.isEmpty == true)
    }

    /// The stored values can't be renamed without migrating existing reports.
    @Test
    func kindsKeepTheirStoredValues() {
        #expect(ReportKind.allCases.map(\.rawValue) == ["construction", "blockedPath", "closedEntrance", "elevatorOut", "other"])
    }

    @Test
    func reportKindsUseTheirSpecifiedLifetimes() {
        #expect(ReportKind.construction.lifetime == 7 * 24 * 60 * 60)
        #expect(ReportKind.blockedPath.lifetime == 4 * 60 * 60)
        #expect(ReportKind.elevatorOut.lifetime == 24 * 60 * 60)
    }

    @Test
    func yesConfirmationExtendsTheReportOnlyOnce() async throws {
        let service = PlaceholderReportService()
        let activeReport = Report(
            id: "active-yes",
            kind: .blockedPath,
            coordinate: report.coordinate,
            createdAt: .now,
            expiresAt: .now.addingTimeInterval(60 * 60),
            reporterID: "report-owner"
        )
        let originalExpiry = activeReport.expiresAt
        try await service.submit(activeReport)

        try await service.confirm(activeReport.id, isStillPresent: true, userID: "reader-1")
        try await service.confirm(activeReport.id, isStillPresent: true, userID: "reader-1")

        let updated = try await service.reports(near: activeReport.coordinate, radius: 100)
        #expect(updated.count == 1)
        #expect(updated[0].confirmations == 1)
        #expect(updated[0].expiresAt > originalExpiry)
    }

    @Test
    func twoDifferentNoAnswersRemoveTheReport() async throws {
        let service = PlaceholderReportService()
        let activeReport = Report(
            id: "active-no",
            kind: .blockedPath,
            coordinate: report.coordinate,
            createdAt: .now,
            expiresAt: .now.addingTimeInterval(60 * 60),
            reporterID: "report-owner"
        )
        try await service.submit(activeReport)

        try await service.confirm(activeReport.id, isStillPresent: false, userID: "reader-1")
        try await service.confirm(activeReport.id, isStillPresent: false, userID: "reader-1")
        let afterOnePerson = try await service.reports(near: activeReport.coordinate, radius: 100)
        #expect(afterOnePerson.count == 1)
        #expect(afterOnePerson[0].negativeConfirmations == 1)
        #expect(!afterOnePerson[0].isRemoved)

        try await service.confirm(activeReport.id, isStillPresent: false, userID: "reader-2")
        let afterTwoPeople = try await service.reports(near: activeReport.coordinate, radius: 100)
        #expect(afterTwoPeople.isEmpty)
    }

    @Test
    func survivesARoundTrip() throws {
        var outlined = report
        outlined.area = [
            GeoCoordinate(latitude: 33.775, longitude: -84.396),
            GeoCoordinate(latitude: 33.776, longitude: -84.396),
            GeoCoordinate(latitude: 33.776, longitude: -84.397),
        ]
        let decoded = try JSONDecoder().decode(Report.self, from: JSONEncoder().encode(outlined))
        #expect(decoded == outlined)
    }
}
