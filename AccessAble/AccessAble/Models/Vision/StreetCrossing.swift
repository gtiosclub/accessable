import CoreGraphics
import Foundation

// T37: traffic lights, stop signs and crosswalks.
//
// Traffic lights and stop signs come straight from YOLO (both are COCO classes). Crosswalks
// aren't a COCO class, so they're found by looking for painted stripes in the lower part of
// the image. This is for awareness only: nothing here ever says a crossing is safe.

/// Small grayscale copy of the camera image, upright, row-major, 0...255.
struct LumaGrid: Sendable {
    let width: Int
    let height: Int
    var values: [UInt8]

    subscript(x: Int, y: Int) -> UInt8 { values[y * width + x] }
}

struct CrosswalkTuning: Sendable {
    /// Part of the image searched, as fractions of its height. The ground is at the bottom.
    var regionTop = 0.5
    var regionBottom = 0.95
    /// Brightness gap between paint and road, out of 255.
    var minimumContrast = 50.0
    var minimumStripes = 3
    /// A run longer than this fraction of the line isn't a stripe.
    var maximumRunFraction = 0.3
    var minimumRunCells = 2
    /// Widest run over narrowest run. Perspective stretches near stripes, so this is loose.
    var maximumWidthRatio = 3.5
    /// Fraction of lines that have to look striped.
    var minimumStripedLines = 0.6

    static let `default` = CrosswalkTuning()
}

private struct Run {
    let bright: Bool
    var length: Int
}

/// True when the line crosses at least `minimumStripes` bright bars separated by dark gaps
/// of similar width. Runs touching either end are ignored since the frame cuts them off.
func isStriped(_ line: [UInt8], tuning: CrosswalkTuning = .default) -> Bool {
    guard line.count >= 8 else { return false }
    let mean = Double(line.reduce(0) { $0 + Int($1) }) / Double(line.count)

    var brightSum = 0.0, brightCount = 0.0, darkSum = 0.0, darkCount = 0.0
    var runs: [Run] = []
    for value in line {
        let bright = Double(value) > mean
        if bright {
            brightSum += Double(value)
            brightCount += 1
        } else {
            darkSum += Double(value)
            darkCount += 1
        }
        if let last = runs.last, last.bright == bright {
            runs[runs.count - 1].length += 1
        } else {
            runs.append(Run(bright: bright, length: 1))
        }
    }
    guard brightCount > 0, darkCount > 0,
          brightSum / brightCount - darkSum / darkCount >= tuning.minimumContrast,
          runs.count > 2 else { return false }

    let inner = runs.dropFirst().dropLast()
    guard inner.count(where: { $0.bright }) >= tuning.minimumStripes else { return false }

    let lengths = inner.map { $0.length }
    let longest = Int(Double(line.count) * tuning.maximumRunFraction)
    guard lengths.allSatisfy({ $0 >= tuning.minimumRunCells && $0 <= longest }),
          let shortest = lengths.min(), let widest = lengths.max() else { return false }
    return Double(widest) / Double(shortest) <= tuning.maximumWidthRatio
}

/// 3-tap average, so one noisy cell doesn't split a stripe.
func smoothed(_ line: [UInt8]) -> [UInt8] {
    guard line.count > 2 else { return line }
    return line.indices.map { i in
        let lo = max(i - 1, 0), hi = min(i + 1, line.count - 1)
        let sum = (lo...hi).reduce(0) { $0 + Int(line[$1]) }
        return UInt8(sum / (hi - lo + 1))
    }
}

/// Where a crosswalk is in the image (normalized, top-left origin), or nil. Zebra stripes
/// run along the walking direction, so they alternate across each row; ladder-style bars
/// run across it, so they alternate down each column. Either counts.
func detectCrosswalk(in grid: LumaGrid, tuning: CrosswalkTuning = .default) -> CGRect? {
    let top = Int(Double(grid.height) * tuning.regionTop)
    let bottom = min(Int(Double(grid.height) * tuning.regionBottom), grid.height)
    guard grid.width >= 8, bottom - top >= 8 else { return nil }
    let region = CGRect(
        x: 0, y: Double(top) / Double(grid.height),
        width: 1, height: Double(bottom - top) / Double(grid.height)
    )

    let rows = (top..<bottom).map { y in (0..<grid.width).map { grid[$0, y] } }
    if fractionStriped(rows, tuning: tuning) >= tuning.minimumStripedLines { return region }

    // middle columns only, the edges are often curb or sidewalk
    let left = grid.width / 5
    let columns = (left..<(grid.width - left)).map { x in (top..<bottom).map { grid[x, $0] } }
    if fractionStriped(columns, tuning: tuning) >= tuning.minimumStripedLines { return region }
    return nil
}

private func fractionStriped(_ lines: [[UInt8]], tuning: CrosswalkTuning) -> Double {
    guard !lines.isEmpty else { return 0 }
    let striped = lines.count(where: { isStriped(smoothed($0), tuning: tuning) })
    return Double(striped) / Double(lines.count)
}

/// One frame of stripes could be a fence or blinds; this wants `required` of the last `window`.
struct CrosswalkConfirmer: Sendable {
    var window = 5
    var required = 3
    private var recent: [CGRect?] = []

    /// The latest box once confirmed, otherwise nil.
    mutating func update(_ sighting: CGRect?) -> CGRect? {
        recent.append(sighting)
        if recent.count > window { recent.removeFirst() }
        guard recent.count(where: { $0 != nil }) >= required else { return nil }
        return recent.compactMap { $0 }.last
    }
}

/// Speaks traffic lights, stop signs and crosswalks once when they show up, then stays
/// quiet about that kind for `repeatInterval`. Keyed by label, not track, because tracks
/// on small far-away boxes split all the time.
struct StreetSignalAnnouncer: Sendable {
    static let labels: Set<String> = ["traffic light", "stop sign", "crosswalk"]

    var confirmationFrames = 2
    var repeatInterval: TimeInterval = 20
    var announcementLifetime: TimeInterval = 3

    private var framesSeen: [String: Int] = [:]
    private var lastSpoken: [String: TimeInterval] = [:]

    mutating func announcements(for detections: [Detection], at time: TimeInterval) -> [AnnouncementEvent] {
        let present = Dictionary(grouping: detections.filter { Self.labels.contains($0.label) }, by: \.label)
        framesSeen = framesSeen.filter { present[$0.key] != nil }

        var events: [AnnouncementEvent] = []
        for label in present.keys.sorted() {
            let count = (framesSeen[label] ?? 0) + 1
            framesSeen[label] = count
            guard count >= confirmationFrames,
                  time - (lastSpoken[label] ?? -.infinity) >= repeatInterval,
                  let nearest = present[label]?.min(by: { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) })
            else { continue }
            lastSpoken[label] = time
            let now = Date()
            events.append(AnnouncementEvent(
                category: .landmark,
                priority: .normal,
                text: Self.phrase(for: nearest),
                distance: nearest.distance,
                bearing: nearest.bearing,
                source: .sceneDescription,
                createdAt: now,
                expiresAt: now.addingTimeInterval(announcementLifetime),
                dedupKey: "street-\(label)"
            ))
        }
        return events
    }

    /// "Stop sign on your right, 4 metres." Without depth there's no bearing, so the side
    /// comes from where the box is in the frame.
    static func phrase(for detection: Detection) -> String {
        if detection.bearing != nil { return SpokenPhrasing.describe(detection) }
        let name = detection.label.prefix(1).uppercased() + detection.label.dropFirst()
        let x = detection.boundingBox.midX
        let side = x < 0.33 ? "on your left" : x < 0.66 ? "ahead" : "on your right"
        return "\(name) \(side)."
    }
}
