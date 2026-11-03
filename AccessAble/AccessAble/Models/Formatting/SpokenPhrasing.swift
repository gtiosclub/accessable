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
    /// "2 metres" for a measurement, "about 2 metres" for an estimate (T33). The hedge is
    /// not politeness: a distance that may be out by half a metre must not be read out in
    /// the same words as one that cannot.
    static func hedgedDistance(_ metres: Double, accuracy: DistanceAccuracy?) -> String {
        switch accuracy {
        case .measured, .none: shortDistance(metres)
        case .estimated: "about \(shortDistance(metres))"
        }
    }

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

    /// "A few people 3 metres ahead." / "About six people, 2 metres to 5 metres ahead,
    /// spread out." — one sentence for a group instead of one per person (T35).
    ///
    /// The count is deliberately approximate: people occlude one another, so the detector's
    /// number is a floor on the real one, and reading it out as exact would overstate what
    /// is known. The group's near edge is what gets the distance, since that is what the
    /// user reaches first.
    static func describe(_ crowd: CrowdRegion) -> String {
        let size = crowdSize(crowd.count)
        let side = direction(crowd.bearing)
        let spread = crowd.isSpreadOut ? ", spread out" : ""
        if crowd.spansDistance {
            let range = "\(shortDistance(crowd.nearestDistance)) to \(shortDistance(crowd.farthestDistance))"
            return "\(size), \(range) \(side)\(spread)."
        }
        if side == "ahead" {
            return "\(size) \(shortDistance(crowd.nearestDistance)) ahead\(spread)."
        }
        return "\(size) \(side), \(shortDistance(crowd.nearestDistance))\(spread)."
    }

    /// "A few people" / "About six people" / "A large group" — a count the detector can
    /// actually support.
    static func crowdSize(_ count: Int) -> String {
        switch count {
        case ..<5: "A few people"
        case ..<10: "About \(count) people"
        default: "A large group"
        }
    }

    /// "Drop-off", "Step up"…
    static func name(of hazard: ElevationHazardType) -> String {
        switch hazard {
        case .stepUp: "Step up"
        case .stepDown: "Step down"
        case .dropOff: "Drop-off"
        case .unknown: "Uneven ground"
        }
    }

    /// "Drop-off 2 metres ahead."
    static func describe(_ hazard: ElevationHazard) -> String {
        "\(name(of: hazard.type)) \(shortDistance(Double(hazard.distance))) ahead."
    }

    // MARK: - Guidance (what the announcer says about the path)

    /// Spoken when the corridor has emptied after a warning.
    static let pathClear = "Path clear."

    /// The sentence for something blocking the path, at the urgency of its distance band:
    ///
    /// - normal: "Chair ahead, 3 metres." — information, no instruction yet.
    /// - high: "Wall ahead. Go left." — the instruction comes from `path`.
    /// - critical: "Stop. Wall ahead. Go left."
    ///
    /// Short on purpose: a warning is heard while walking, and the band already says how
    /// close. The place is always "ahead" because the thing is in the corridor; the side
    /// says which part of the corridor it occupies.
    static func guidance(for detection: Detection, priority: AnnouncementPriority, path: PathAssessment?) -> String {
        let name = detection.label.prefix(1).uppercased() + detection.label.dropFirst()
        let place = placeInPath(detection.bearing)
        var sentences: [String] = []
        if priority == .critical {
            sentences.append("Stop.")
            sentences.append("\(name) \(place).")
        } else if priority == .normal, let distance = detection.distance {
            sentences.append("\(name) \(place), \(hedgedDistance(distance, accuracy: detection.distanceAccuracy)).")
        } else {
            sentences.append("\(name) \(place).")
        }
        if priority >= .high, let advice = advice(for: path, bearing: detection.bearing, critical: priority == .critical) {
            sentences.append(advice)
        }
        return sentences.joined(separator: " ")
    }

    /// "Car approaching from your right." / "Stop. Cyclist from your left." (T34)
    ///
    /// Where it is coming *from* rather than where it is, which is what the listener needs:
    /// a static obstacle is somewhere to be avoided, while an approaching one is a direction
    /// to turn away from.
    static func guidance(for threat: ApproachThreat, priority: AnnouncementPriority) -> String {
        let name = threat.label.prefix(1).uppercased() + threat.label.dropFirst()
        let side = approachSide(threat.bearing)
        if priority == .critical {
            return "Stop. \(name) \(side)."
        }
        return "\(name) approaching \(side)."
    }

    /// "from your left" / "from behind" / "ahead" — the direction an approach is coming from.
    static func approachSide(_ bearing: RelativeBearing) -> String {
        switch bearing.side {
        case .slightlyLeft, .left: "from your left"
        case .slightlyRight, .right: "from your right"
        case .behind: "from behind"
        case .ahead: "ahead"
        }
    }

    /// "Step down ahead, 2 metres." / "Stop. Drop-off ahead."
    static func guidance(for hazard: ElevationHazard, priority: AnnouncementPriority) -> String {
        let name = name(of: hazard.type)
        if priority == .critical { return "Stop. \(name) ahead." }
        return "\(name) ahead, \(shortDistance(Double(hazard.distance)))."
    }

    /// "Go left." / "Keep right." / "Turn left." / "Narrow gap ahead." — what to do about
    /// what is in the way. "Go" is a sidestep into a gap that was seen; "Turn" means nothing
    /// passable is in view and that side has more room. nil when there is nothing to add.
    static func advice(for path: PathAssessment?, bearing: RelativeBearing?, critical: Bool) -> String? {
        guard let path else { return nil }
        switch path.clearDirection {
        case .left: return "Go left."
        case .right: return "Go right."
        case .blocked:
            if let turn = path.turn { return turn == .left ? "Turn left." : "Turn right." }
            return critical ? "No clear path. Turn around slowly." : nil
        case .ahead:
            if path.isNarrow { return "Narrow gap ahead." }
            if let sidestep = path.sidestep, abs(sidestep) >= 0.15 {
                return sidestep < 0 ? "Keep left." : "Keep right."
            }
            switch bearing?.side {
            case .slightlyRight, .right: return "Keep left."
            case .slightlyLeft, .left: return "Keep right."
            default: return nil
            }
        }
    }

    /// Where in the corridor something is: "ahead", "ahead on your left", "ahead on your right".
    static func placeInPath(_ bearing: RelativeBearing?) -> String {
        switch bearing?.side {
        case .slightlyLeft, .left: "ahead on your left"
        case .slightlyRight, .right: "ahead on your right"
        case .behind: "behind you"
        default: "ahead"
        }
    }
}
