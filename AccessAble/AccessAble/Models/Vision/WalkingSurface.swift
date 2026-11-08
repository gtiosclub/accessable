import CoreGraphics
import Foundation

// What the ground is made of, from semantic segmentation (Apple's Core ML DETR, COCO-panoptic
// labels). Owner: Computer Vision (1.1). After PathSense and SENSATION: geometry says where
// the ground changes height; segmentation says whether it is floor, pavement, road or stairs.

/// The ground classes that matter for walking, from the model's 133 labels.
enum SurfaceKind: String, Sendable {
    /// Indoor floor, carpet or rug.
    case floor
    case pavement
    case road
    case grass
    /// Dirt, gravel, sand: walkable but uneven.
    case rough
    case stairs
    case water
    case rail
    /// Table, counter, shelf: a raised surface that is not the ground.
    case raised
    /// Sky, trees, buildings: evidence the camera is outdoors.
    case outdoors
    /// Ceiling and ceiling lights: evidence it is indoors.
    case ceiling
    case other

    init(label: String) {
        self = switch label {
        case "floor (wood)", "floor (other)", "rug", "platform", "playingfield": .floor
        case "pavement": .pavement
        case "road": .road
        case "grass": .grass
        case "dirt", "gravel", "sand", "snow": .rough
        case "stairs": .stairs
        case "river", "sea", "water (other)": .water
        case "railroad": .rail
        case "table", "dining table", "counter", "shelf", "cabinet", "bed": .raised
        case "sky (other)", "tree", "building (other)", "house", "mountain": .outdoors
        case "ceiling", "light": .ceiling
        default: .other
        }
    }

    /// Level ground a step or drop can't hide in: if it is on both sides of a "drop", there
    /// is no drop. Road counts: the model calls grey carpet "road" or "pavement" as often
    /// as "floor", and all three are level.
    var isFlatGround: Bool { self == .floor || self == .pavement || self == .road }

    /// Only trusted with outdoor evidence in view: indoors, grey carpet reads as road.
    var needsOutdoorEvidence: Bool { self == .road || self == .water || self == .rail }

    /// Spoken when it fills the ground ahead; nil for surfaces not worth a word.
    var warning: String? {
        switch self {
        case .road: "Road ahead."
        case .stairs: "Stairs ahead."
        case .water: "Water ahead."
        case .rail: "Railway track ahead."
        default: nil
        }
    }
}

extension DangerLevel {
    init(of surface: SurfaceKind) {
        self = switch surface {
        case .road, .rail, .water: .critical
        case .stairs: .high
        default: .low
        }
    }
}

/// One segmentation of a camera image, downsampled, upright, top-left origin.
struct SurfaceMap: Sendable {
    let width: Int
    let height: Int
    /// Row by row, `width * height` cells.
    let kinds: [SurfaceKind]
    /// Increases with every new segmentation, so two maps can be told apart as two reads.
    let generation: Int

    /// The image region the ground about 1 to 3 m ahead falls in, with the phone at chest
    /// height pointing forward and a little down: bottom middle, short of the very bottom.
    static let groundAhead = CGRect(x: 0.35, y: 0.55, width: 0.3, height: 0.3)

    /// The kind at a normalized upright point, nil outside the image.
    func kind(at point: CGPoint) -> SurfaceKind? {
        guard (0 ..< 1).contains(point.x), (0 ..< 1).contains(point.y) else { return nil }
        let column = min(Int(point.x * CGFloat(width)), width - 1)
        let row = min(Int(point.y * CGFloat(height)), height - 1)
        return kinds[row * width + column]
    }

    /// Share of the whole image that is `kind`.
    func share(of kind: SurfaceKind) -> Float {
        Float(kinds.count { $0 == kind }) / Float(max(kinds.count, 1))
    }

    /// Sky, trees or buildings in view and no ceiling. On field recordings indoors, the
    /// outdoor share was 0% in every frame, while the model still called carpet "road".
    var looksOutdoors: Bool { share(of: .outdoors) >= 0.05 && share(of: .ceiling) < 0.02 }

    /// The most common kind in `rect` (normalized) and its share of the cells.
    func dominant(in rect: CGRect) -> (kind: SurfaceKind, share: Float)? {
        let columns = max(0, Int(rect.minX * CGFloat(width))) ..< min(width, Int(rect.maxX * CGFloat(width)))
        let rows = max(0, Int(rect.minY * CGFloat(height))) ..< min(height, Int(rect.maxY * CGFloat(height)))
        guard !columns.isEmpty, !rows.isEmpty else { return nil }
        var counts: [SurfaceKind: Int] = [:]
        for row in rows {
            for column in columns { counts[kinds[row * width + column], default: 0] += 1 }
        }
        guard let top = counts.max(by: { $0.value < $1.value }) else { return nil }
        return (top.key, Float(top.value) / Float(columns.count * rows.count))
    }
}

/// Drops a step down or drop-off when segmentation sees the same flat floor or pavement just
/// before and just after it, and no stairs at it: a hole in depth on a dark rug or a glossy
/// floor, not an edge. Pavement before road (a kerb) or stairs keep it.
///
/// `surface(d)` gives the kind of the ground `d` metres ahead along the walking direction, nil
/// when that point is out of view.
func checkingSurface(
    _ hazards: [ElevationHazard],
    margin: Float = 0.3,
    surface: (Float) -> SurfaceKind?
) -> [ElevationHazard] {
    hazards.map { hazard in
        guard hazard.type == .stepDown || hazard.type == .dropOff,
              let before = surface(hazard.distance - margin),
              let after = surface(hazard.distance + margin),
              before.isFlatGround, before == after,
              surface(hazard.distance) != .stairs
        else { return hazard }
        return ElevationHazard(type: .unknown, distance: hazard.distance, heightChange: 0)
    }
}

/// Speaks the surface ahead once it has filled the ground ahead in two separate segmentations:
/// "Road ahead.", "Stairs ahead." Not again for `repeatInterval` unless it changes.
struct SurfaceAnnouncer: Sendable {
    /// Share of the ground ahead a surface must cover.
    var minimumShare: Float = 0.5
    var confirmations = 2
    var repeatInterval: TimeInterval = 20
    var announcementLifetime: TimeInterval = 2

    private var candidate: SurfaceKind?
    private var seenIn: Set<Int> = []
    private var lastSpoken: [SurfaceKind: TimeInterval] = [:]

    init() {}

    mutating func announcements(for map: SurfaceMap?, at time: TimeInterval, now: Date = .now) -> [AnnouncementEvent] {
        guard let map, let (kind, share) = map.dominant(in: SurfaceMap.groundAhead),
              share >= minimumShare, let text = kind.warning,
              !kind.needsOutdoorEvidence || map.looksOutdoors
        else {
            candidate = nil
            seenIn = []
            return []
        }
        if kind != candidate {
            candidate = kind
            seenIn = []
        }
        seenIn.insert(map.generation)
        guard seenIn.count >= confirmations, time - (lastSpoken[kind] ?? -.infinity) >= repeatInterval else { return [] }
        lastSpoken[kind] = time
        return [AnnouncementEvent(
            category: .hazard,
            priority: .high,
            text: text,
            haptic: .attention,
            bearing: .ahead,
            source: .obstacleDetection,
            createdAt: now,
            expiresAt: now.addingTimeInterval(announcementLifetime),
            dedupKey: "surface-ahead-\(kind.rawValue)"
        )]
    }
}
