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
            "negativeConfirmations", "negativesSinceConfirm"
        ])
        #expect(fields["kind"] as? String == "blockedPath")
        #expect(fields["confirmations"] as? Int == 0)
        #expect(fields["negativeConfirmations"] as? Int == 0)
        #expect(fields["negativesSinceConfirm"] as? Int == 0)
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
        #expect(ReportKind.closedEntrance.lifetime == 4 * 60 * 60)
        #expect(ReportKind.other.lifetime == 4 * 60 * 60)
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

    /// Reports from before REPORT-6 have no vote counts.
    @Test
    func decodesWithoutTheVoteCounts() throws {
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        for key in ["confirmations", "negativeConfirmations", "negativesSinceConfirm"] { fields[key] = nil }
        let decoded = try JSONDecoder().decode(Report.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(decoded == report)
    }
}
