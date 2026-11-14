import Foundation
enum ReportKind: String, Codable, CaseIterable, Sendable {
    case construction
    case blockedPath
    case closedEntrance
    case elevatorOut
    case other
}

struct Report: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: ReportKind
    var corrdinate: GeoCoordinate
    var area: [GeoCoordinate]? = nil
    var createdAt: Date
    var expiresAt: Date
    var confirmations: Int = 0
    var reporterID: String
    
}
