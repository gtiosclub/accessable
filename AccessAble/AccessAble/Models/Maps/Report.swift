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
    var confirmations: Int = 0
    var reporterID: String

    /// Whether the report's point, or any corner of its area, is within `radius` metres.
    func isNear(_ coordinate: GeoCoordinate, within radius: Double) -> Bool {
        ([self.coordinate] + (area ?? [])).contains {
            GeoMath.distance(from: coordinate, to: $0) <= radius
        }
    }
}
