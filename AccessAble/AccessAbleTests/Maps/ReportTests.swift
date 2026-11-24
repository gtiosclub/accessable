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

        #expect(Set(fields.keys) == ["id", "kind", "coordinate", "createdAt", "expiresAt", "confirmations", "reporterID"])
        #expect(fields["kind"] as? String == "blockedPath")
        #expect(fields["confirmations"] as? Int == 0)
    }

    /// The stored values can't be renamed without migrating existing reports.
    @Test
    func kindsKeepTheirStoredValues() {
        #expect(ReportKind.allCases.map(\.rawValue) == ["construction", "blockedPath", "closedEntrance", "elevatorOut", "other"])
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
