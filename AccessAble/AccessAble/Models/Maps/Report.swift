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

    /// Asked once the user has walked past a report of this kind; a yes confirms it, a no counts against it.
    var stillThereQuestion: String {
        switch self {
        case .blockedPath, .construction: "Is the path still blocked here?"
        case .closedEntrance: "Is the entrance still closed?"
        case .elevatorOut: "Is the elevator still out of service?"
        case .other: "Is the reported problem still there?"
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
    /// "No" answers, and those since the last "yes": the second of those ends the report.
    var negativeConfirmations: Int = 0
    var negativesSinceConfirm: Int = 0
    /// Whether the signed-in user reported it. Reports don't say who reported them, so this comes from the user's
    /// private list of their own, and is never encoded.
    var isOwn: Bool = false

    /// Metres to the report's point or the nearest corner of its area.
    func distance(from coordinate: GeoCoordinate) -> Double {
        ([self.coordinate] + (area ?? [])).map { GeoMath.distance(from: coordinate, to: $0) }.min() ?? .infinity
    }

    /// Whether the report's point, or any corner of its area, is within `radius` metres.
    func isNear(_ coordinate: GeoCoordinate, within radius: Double) -> Bool {
        ([self.coordinate] + (area ?? [])).contains {
            GeoMath.distance(from: coordinate, to: $0) <= radius
        }
    }
}

/// A question about a report the user just walked past, asked once a trip.
struct ReportQuestion: Equatable, Sendable {
    let report: Report
    let askedAt: Date
}

/// How the screen ended a report question.
enum ReportQuestionOutcome: Equatable, Sendable {
    /// Not put to the user, so it may be asked again.
    case notAsked
    /// Asked, with no vote sent: no answer, or one that couldn't be sent.
    case unanswered
    /// Asked and answered with a vote, so the next waits out the rules' one vote a minute.
    case voted
}

extension Report {
    private enum CodingKeys: String, CodingKey {
        case id, kind, coordinate, area, createdAt, expiresAt, confirmations
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
            negativeConfirmations: try container.decodeIfPresent(Int.self, forKey: .negativeConfirmations) ?? 0,
            negativesSinceConfirm: try container.decodeIfPresent(Int.self, forKey: .negativesSinceConfirm) ?? 0
        )
    }
}
