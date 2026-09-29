import Foundation

/// Shared rules for turning numbers into speech so every subteam sounds the same.
enum SpokenPhrasing {
    /// Rounds to the nearest 0.5 m: "about 2 metres", "about 1.5 metres", "less than half a metre".
    static func distance(_ metres: Double) -> String {
        let rounded = (metres * 2).rounded() / 2
        if rounded < 0.5 { return "less than half a metre" }
        if rounded == 1 { return "about 1 metre" }
        let number = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "about \(number) metres"
    }

    /// Short form for scene lists: "2 metres", "1.5 metres".
    static func shortDistance(_ metres: Double) -> String {
        let rounded = max((metres * 2).rounded() / 2, 0.5)
        if rounded == 1 { return "1 metre" }
        let number = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(number) metres"
    }

    static func direction(_ bearing: RelativeBearing) -> String {
        switch bearing.side {
        case .ahead: "ahead"
        case .slightlyLeft: "slightly left"
        case .slightlyRight: "slightly right"
        case .left: "on your left"
        case .right: "on your right"
        case .behind: "behind you"
        }
    }

    /// "Person 2 metres ahead." / "Chair on your left, 1 metre." — the Tier A sentence template.
    static func describe(_ detection: Detection) -> String {
        let label = detection.label.prefix(1).uppercased() + detection.label.dropFirst()
        let side = detection.bearing.map { direction($0) } ?? "ahead"
        guard let distance = detection.distance else { return "\(label) \(side)." }
        if side == "ahead" {
            return "\(label) \(shortDistance(distance)) ahead."
        }
        return "\(label) \(side), \(shortDistance(distance))."
    }
}
