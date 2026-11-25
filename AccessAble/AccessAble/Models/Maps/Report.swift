import Foundation
enum ReportKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case construction
    case blockedPath
    case closedEntrance
    case elevatorOut
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .construction: "Construction"
        case .blockedPath: "Blocked path"
        case .closedEntrance: "Closed entrance"
        case .elevatorOut: "Elevator out of service"
        case .other: "Other problem"
        }
    }

    var lifetime: TimeInterval {
        switch self {
        case .construction: 7 * 24 * 60 * 60
        case .blockedPath, .closedEntrance, .other: 4 * 60 * 60
        case .elevatorOut: 24 * 60 * 60
        }
    }
}

struct Report: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: ReportKind
    var coordinate: GeoCoordinate
    var area: [GeoCoordinate]? = nil
    var createdAt: Date
    var expiresAt: Date
    /// "Yes, still there" answers.
    var confirmations: Int = 0
    var reporterID: String
    /// "No" answers, and those since the last "yes": the second of those ends the report.
    var negativeConfirmations: Int = 0
    var negativesSinceConfirm: Int = 0

    /// Whether the report's point, or any corner of its area, is within `radius` metres.
    func isNear(_ coordinate: GeoCoordinate, within radius: Double) -> Bool {
        ([self.coordinate] + (area ?? [])).contains {
            GeoMath.distance(from: coordinate, to: $0) <= radius
        }
    }
}

extension Report {
    private enum CodingKeys: String, CodingKey {
        case id, kind, coordinate, area, createdAt, expiresAt, confirmations, reporterID
        case negativeConfirmations, negativesSinceConfirm
    }

    /// The vote counts default to none, since reports from before REPORT-6 have none.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            kind: try container.decode(ReportKind.self, forKey: .kind),
            coordinate: try container.decode(GeoCoordinate.self, forKey: .coordinate),
            area: try container.decodeIfPresent([GeoCoordinate].self, forKey: .area),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            expiresAt: try container.decode(Date.self, forKey: .expiresAt),
            confirmations: try container.decodeIfPresent(Int.self, forKey: .confirmations) ?? 0,
            reporterID: try container.decode(String.self, forKey: .reporterID),
            negativeConfirmations: try container.decodeIfPresent(Int.self, forKey: .negativeConfirmations) ?? 0,
            negativesSinceConfirm: try container.decodeIfPresent(Int.self, forKey: .negativesSinceConfirm) ?? 0
        )
    }
}
