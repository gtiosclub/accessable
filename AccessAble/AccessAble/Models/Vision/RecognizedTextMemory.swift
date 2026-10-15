import Foundation

/// Remembers recently read text so each sign is reported once, not once per read.
/// Owner: Computer Vision (1.3 / task T17).
///
/// Readings are matched case- and whitespace-insensitively; a repeat replaces the earlier
/// reading (keeping the newer position) rather than adding a duplicate. Text not read
/// again within `retention` is forgotten, so a sign the user has walked past drops out.
struct RecognizedTextMemory: Sendable {
    /// How long, in seconds, text stays after it was last read.
    var retention: TimeInterval = 3

    private var entries: [String: (text: RecognizedText, lastRead: TimeInterval)] = [:]

    init() {}

    /// Records one read of a frame.
    mutating func record(_ texts: [RecognizedText], at time: TimeInterval) {
        for text in texts {
            entries[Self.key(for: text.string)] = (text, time)
        }
    }

    /// Text read within the retention window, highest confidence first.
    mutating func current(at time: TimeInterval) -> [RecognizedText] {
        entries = entries.filter { time - $0.value.lastRead <= retention }
        return entries.values.map(\.text).sorted { $0.confidence > $1.confidence }
    }

    private static func key(for string: String) -> String {
        string.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
