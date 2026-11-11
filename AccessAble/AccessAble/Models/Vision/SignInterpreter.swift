import Foundation

// Signs (T17 / T29): what a plate says, normalized for speech and for "take me to…".
// Adapted from InView's AccessCore `SignInterpreter` (github.com/isolume/InView), with OCR
// digit repair added for room numbers.

/// What a sign names, normalized for people and for matching: "RM. 204" reads as "Room 204",
/// "WOMEN" as "Women's restroom". Arrows mean the sign points somewhere else.
struct SignReading: Hashable, Sendable {
    enum Category: String, Sendable {
        case room, exit, restroom, elevator, stairs, lobby, office
    }

    var category: Category
    /// Short spoken name: "Room 204", "Emergency exit", "Main lobby".
    var title: String
    /// Other text on the same plate, like "Chemistry Lab" under a room number.
    var detail: String?
    /// The room number as printed, OCR-repaired: "204A", "B-204", "0266".
    var roomNumber: String?
    /// Arrows or direction words printed on the sign, relative to the sign itself.
    var directions: [String] = []

    /// "Room 204, Chemistry Lab", or just the title.
    var spokenTitle: String {
        guard let detail, !detail.isEmpty, detail.caseInsensitiveCompare(title) != .orderedSame else { return title }
        return "\(title), \(detail)"
    }
}

/// Reads the lines of one sign plate into a `SignReading`. Deterministic and offline, so it
/// works at camera rate. nil for text that isn't a sign: posters, prices, phone numbers.
enum SignInterpreter {
    /// Posters and notices are long; signs are a few words.
    static let maximumWords = 9

    static func interpret(_ lines: [String]) -> SignReading? {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        let joined = cleaned.joined(separator: " ")
        let upper = joined.uppercased()
        let tokens = Self.tokens(upper)
        let words = Set(tokens)
        guard !tokens.isEmpty, tokens.count <= maximumWords else { return nil }
        // Prices, times, percentages and phone numbers aren't room signs.
        guard upper.rangeOfCharacter(from: CharacterSet(charactersIn: "$%@:")) == nil else { return nil }
        let directions = Self.directions(in: upper, words: words)

        if !words.isDisjoint(with: ["EXIT", "EXITS", "EGRESS", "SALIDA", "SORTIE"]) {
            guard words.isDisjoint(with: ["NO", "NOT"]) else { return nil }
            let title = words.contains("FIRE") ? "Fire exit" : words.contains("EMERGENCY") ? "Emergency exit" : "Exit"
            return SignReading(category: .exit, title: title, directions: directions)
        }
        if !words.isDisjoint(with: ["ELEVATOR", "ELEVATORS", "LIFT", "LIFTS"]) {
            return SignReading(category: .elevator, title: "Elevator", directions: directions)
        }
        if !words.isDisjoint(with: ["STAIR", "STAIRS", "STAIRCASE", "STAIRWAY", "STAIRWELL"]) {
            let letter = tokens.first { $0.count == 1 && $0.first?.isLetter == true }
            return SignReading(category: .stairs, title: letter.map { "Stair \($0)" } ?? "Stairs", directions: directions)
        }
        if let restroom = restroomTitle(words) {
            return SignReading(
                category: .restroom, title: restroom, roomNumber: roomNumber(in: tokens)?.number, directions: directions
            )
        }
        if let found = roomNumber(in: tokens) {
            let isSuite = words.contains("SUITE") || words.contains("STE")
            return SignReading(
                category: .room, title: "\(isSuite ? "Suite" : "Room") \(found.number)",
                detail: detailText(cleaned, excluding: found.consumed), roomNumber: found.number, directions: directions
            )
        }
        if !words.isDisjoint(with: ["LOBBY", "ATRIUM", "FOYER", "RECEPTION"]) {
            let title = words.contains("MAIN") ? "Main lobby" : titleCase(joined)
            return SignReading(category: .lobby, title: title.count <= 40 ? title : "Lobby", directions: directions)
        }
        if !words.isDisjoint(with: ["OFFICE", "OFFICES", "LAB", "LABORATORY", "CLASSROOM", "CONFERENCE", "LOUNGE",
                                    "LIBRARY", "CAFE", "CAFETERIA", "BALLROOM", "THEATER", "THEATRE", "AUDITORIUM"]) {
            return SignReading(category: .office, title: titleCase(joined), directions: directions)
        }
        return nil
    }

    static func tokens(_ upper: String) -> [String] {
        upper.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { !$0.isEmpty }
    }

    /// "204", "204A", "B-204", "RM 204", "O266" (OCR for 0266) → the number, without "ROOM".
    static func roomNumber(in tokens: [String]) -> (number: String, consumed: Set<String>)? {
        let prefixes: Set<String> = ["ROOM", "RM", "SUITE", "STE", "NO"]
        for (index, raw) in tokens.enumerated() {
            let token = repairingDigits(raw)
            guard token.range(of: #"^([A-Z]{1,3}-?)?[0-9]{2,4}[A-Z]?$"#, options: .regularExpression) != nil else { continue }
            let digits = token.filter(\.isNumber)
            // A bare four-digit number is usually a year, not a room.
            if token.allSatisfy(\.isNumber), digits.count == 4, digits.hasPrefix("19") || digits.hasPrefix("20") { continue }
            var consumed: Set<String> = [raw]
            if index > 0, prefixes.contains(tokens[index - 1]) { consumed.insert(tokens[index - 1]) }
            return (token, consumed)
        }
        return nil
    }

    /// OCR reads 0 as O, and 1 as I or L, inside numbers. In a token that is mostly digits,
    /// put them back: "O266" → "0266", "2I4" → "214". A trailing letter ("204A") is kept, and a
    /// leading I or L stays a letter ("L204" is a wing, not room 1204).
    static func repairingDigits(_ token: String) -> String {
        let digits = token.filter(\.isNumber).count
        guard digits >= 2, digits * 2 >= token.count else { return token }
        let keepsSuffix = token.count > 1 && token.last?.isLetter == true && token.dropLast().last?.isNumber == true
        let body = keepsSuffix ? String(token.dropLast()) : token
        let repaired = body.enumerated().map { index, character -> Character in
            switch character {
            case "O": "0"
            case "I", "L" where index > 0: "1"
            default: character
            }
        }
        return String(repaired) + (keepsSuffix ? String(token.last!) : "")
    }

    /// Whether two room numbers are the same room: digits compared without leading zeros, so
    /// "Room 0266" finds a plate reading "266", and letters must agree when both have one.
    static func sameRoom(_ a: String, _ b: String) -> Bool {
        func parts(_ number: String) -> (digits: String, letters: String) {
            let digits = String(number.filter(\.isNumber).drop { $0 == "0" })
            return (digits, number.filter(\.isLetter).uppercased())
        }
        let (x, y) = (parts(repairingDigits(a.uppercased())), parts(repairingDigits(b.uppercased())))
        guard !x.digits.isEmpty, x.digits == y.digits else { return false }
        return x.letters.isEmpty || y.letters.isEmpty || x.letters == y.letters
    }

    private static func directions(in upper: String, words: Set<String>) -> [String] {
        let rules: [(String, [String])] = [
            ("left", ["←", "⬅", "LEFT"]), ("right", ["→", "➡", "RIGHT"]),
            ("ahead", ["↑", "⬆", "AHEAD", "STRAIGHT"]), ("back", ["↓", "⬇"]),
            ("upstairs", ["UPSTAIRS"]), ("downstairs", ["DOWNSTAIRS"]),
        ]
        return rules.compactMap { name, marks in
            marks.contains { $0.first?.isLetter == true ? words.contains($0) : upper.contains($0) } ? name : nil
        }
    }

    private static func restroomTitle(_ words: Set<String>) -> String? {
        let general: Set<String> = ["RESTROOM", "RESTROOMS", "TOILET", "TOILETS", "WC", "BATHROOM", "BATHROOMS", "LAVATORY"]
        let women: Set<String> = ["WOMEN", "WOMENS", "WOMAN", "LADIES", "FEMALE"]
        let men: Set<String> = ["MEN", "MENS", "GENTLEMEN", "MALE"]
        let isWomen = !words.isDisjoint(with: women), isMen = !words.isDisjoint(with: men)
        let isGeneral = !words.isDisjoint(with: general)
        if words.contains("GENDER") || words.contains("UNISEX") || words.contains("FAMILY") && isGeneral {
            return "All-gender restroom"
        }
        if isWomen && !isMen { return "Women's restroom" }
        if isMen && !isWomen { return "Men's restroom" }
        return isGeneral || (isWomen && isMen) ? "Restroom" : nil
    }

    /// The plate's other words, like "CHEMISTRY LAB", in title case.
    private static func detailText(_ lines: [String], excluding consumed: Set<String>) -> String? {
        let remaining = lines.joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { word in
                let core = word.uppercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                return !core.isEmpty && !consumed.contains(core) && core.contains(where: \.isLetter)
            }
            .joined(separator: " ")
        let text = titleCase(remaining)
        return text.filter(\.isLetter).count >= 3 ? text : nil
    }

    static func titleCase(_ text: String) -> String {
        text.split(separator: " ").map { word in
            let lower = word.lowercased()
            return lower.count <= 2 && ["of", "to", "&", "a", "an"].contains(lower) ? lower : lower.capitalized
        }.joined(separator: " ")
    }
}
