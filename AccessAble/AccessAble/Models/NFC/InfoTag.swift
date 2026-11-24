import Foundation

/// An NFC sticker a volunteer has placed and described. The sticker itself only holds `id`
/// (as an `InfoTagLink` URL); the description and map position live in an `InfoTagRepository`.
struct InfoTag: Identifiable, Codable, Hashable, Sendable {
    let id: String
    /// Where the volunteer was standing when they set the tag up. Drives the map pin.
    var coordinate: GeoCoordinate
    /// The volunteer-written description of the surroundings. Empty until someone writes one.
    var text: String
    var createdAt: Date
    var updatedAt: Date

    init(id: String, coordinate: GeoCoordinate, text: String = "", createdAt: Date = .now, updatedAt: Date? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    var hasDescription: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What is read aloud to a blind user.
    var spokenText: String {
        hasDescription ? text : "No description has been added for this tag yet."
    }
}

/// The URL written onto a sticker: `accessable://tag/<id>`. Only the ID is stored, so a
/// description can change without anyone rewriting the sticker.
enum InfoTagLink {
    static let scheme = "accessable"
    static let host = "tag"

    static func url(for id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + id
        // Built from fixed parts and a UUID string, so it is always a valid URL.
        return components.url!
    }

    /// The tag ID in an AccessAble link, or nil for any other URL.
    static func tagID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == host else { return nil }
        let id = url.lastPathComponent
        guard !id.isEmpty, id != "/" else { return nil }
        return id
    }

    static func newID() -> String {
        UUID().uuidString.lowercased()
    }
}
