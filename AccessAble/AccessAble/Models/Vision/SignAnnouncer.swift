import CoreGraphics
import Foundation

/// Reads signs aloud with where they are: "Room 204, Chemistry Lab. 1 o'clock, 3 metres."
/// Owner: Computer Vision (1.3 / T17, T29). After InView's sign reader.
///
/// - Lines that sit together on one plate are read as one sign, so "RM 204" and "CHEMISTRY
///   LAB" become one sentence.
/// - A sign is spoken only once two separate OCR reads agree on it, so a half-read plate
///   isn't announced as something else.
/// - The same sign is not repeated for `repeatInterval`.
/// - Where it is comes from depth (the clock direction and distance); without depth it is
///   spoken without them rather than guessed.
/// - In Read mode (`readsAllText`), text that isn't a sign is read out as it is.
struct SignAnnouncer: Sendable {
    var agreeingReads = 2
    var repeatInterval: TimeInterval = 30
    var announcementLifetime: TimeInterval = 3
    /// Read mode: also read text that isn't a sign, such as a notice or a menu.
    var readsAllText = false
    /// Plain text is read only above this confidence; signs are checked by the interpreter.
    var minimumTextConfidence: Float = 0.5
    /// A sign not seen for this long starts its agreement count again.
    var forgetAfter: TimeInterval = 5

    /// Per sign, the reads that saw it (each OCR read gives its lines new IDs, so the first
    /// line's ID stands for the read) and when it was last seen.
    private var reads: [String: (ids: Set<UUID>, lastSeen: TimeInterval)] = [:]
    private var lastSpoken: [String: TimeInterval] = [:]

    init() {}

    mutating func announcements(
        for texts: [RecognizedText],
        heading: WalkingCorridor?,
        at time: TimeInterval,
        now: Date = .now
    ) -> [AnnouncementEvent] {
        reads = reads.filter { time - $0.value.lastSeen <= forgetAfter }
        var events: [AnnouncementEvent] = []
        for plate in Self.plates(texts) {
            guard let (key, sentence) = phrase(plate) else { continue }
            var entry = reads[key] ?? ([], time)
            entry.ids.insert(plate[0].id)
            entry.lastSeen = time
            reads[key] = entry
            guard entry.ids.count >= agreeingReads,
                  time - (lastSpoken[key] ?? -.infinity) >= repeatInterval
            else { continue }
            lastSpoken[key] = time

            let position = plate.compactMap(\.worldPosition).first
            var text = sentence
            if let position, let heading {
                let bearing = heading.bearing(to: position)
                let distance = Double(heading.distance(to: position))
                text += " \(SpokenPhrasing.clock(bearing)), \(SpokenPhrasing.shortDistance(distance))."
            }
            events.append(AnnouncementEvent(
                category: .landmark,
                priority: .normal,
                text: text,
                distance: position.flatMap { position in heading.map { Double($0.distance(to: position)) } },
                bearing: position.flatMap { position in heading.map { $0.bearing(to: position) } },
                source: .textRecognition,
                createdAt: now,
                expiresAt: now.addingTimeInterval(announcementLifetime),
                dedupKey: "sign-\(key)"
            ))
        }
        return events
    }

    /// The sentence for one plate and the key it is remembered by; nil when it isn't worth reading.
    private func phrase(_ plate: [RecognizedText]) -> (key: String, sentence: String)? {
        let lines = plate.map(\.string)
        if let reading = SignInterpreter.interpret(lines) {
            var sentence = reading.spokenTitle
            if let direction = reading.directions.first, ["left", "right", "ahead"].contains(direction) {
                sentence += ", arrow pointing \(direction == "ahead" ? "straight ahead" : direction)"
            }
            return (reading.spokenTitle.lowercased(), sentence + ".")
        }
        guard readsAllText else { return nil }
        let confidence = plate.map(\.confidence).reduce(0, +) / Float(plate.count)
        let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard confidence >= minimumTextConfidence, text.filter(\.isLetter).count >= 3 else { return nil }
        let key = text.lowercased().filter { $0.isLetter || $0.isNumber }
        return (key, text.hasSuffix(".") ? text : text + ".")
    }

    /// Lines grouped into plates: lines that overlap horizontally and are stacked within about
    /// a line's height of each other, top to bottom.
    static func plates(_ texts: [RecognizedText]) -> [[RecognizedText]] {
        let lines = texts.sorted { $0.boundingBox.minY < $1.boundingBox.minY }
        var plates: [[RecognizedText]] = []
        for line in lines {
            let box = line.boundingBox
            if let index = plates.lastIndex(where: { plate in
                guard let last = plate.last?.boundingBox else { return false }
                let overlapsAcross = min(box.maxX, last.maxX) > max(box.minX, last.minX)
                let gap = box.minY - last.maxY
                return overlapsAcross && gap <= 1.2 * max(box.height, last.height)
            }) {
                plates[index].append(line)
            } else {
                plates.append([line])
            }
        }
        return plates
    }
}
