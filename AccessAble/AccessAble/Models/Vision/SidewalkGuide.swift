import Foundation

// Keeping to the sidewalk (1.1, outdoor navigation).
//
// People walking without sight drift sideways, a few degrees per stride, and outdoors the
// drift that matters is off the sidewalk into the road. LiDAR can't tell the two apart: both
// are flat. Segmentation can, so the ground around the walking line is sampled in metres —
// 0.8 to 3.5 m ahead, 1.5 m either side — by projecting each ground point into the latest
// segmentation. Sampling the world rather than a fixed patch of the image means the answer
// doesn't change with how the phone is tilted.
//
// What is said, and only outdoors (sky, trees or buildings in view and no ceiling):
// - "Road close on your right. Keep left." — the sidewalk is underfoot and road starts within
//   a metre of the walking line;
// - "You may be in the road. Sidewalk on your left." — road underfoot, sidewalk to one side;
// - "Curb ahead, about 2 metres. Road beyond." — the sidewalk ends straight ahead.
//
// Each needs two separate segmentations to agree before it is spoken, and repeats are held
// back, so a shadow or a manhole cover says nothing. "In the road" is not said while crossing at
// a crosswalk. Segmentation still calls about a fifth of sidewalk pixels road on street photos
// (benchmark in `SurfaceReader`), which is why the lane must be mostly road, twice, before it is.

/// The surface around the walking line, sampled on a grid in metres.
struct GroundLayout: Sendable {
    /// Distances ahead, metres.
    static let alongs: [Float] = [0.8, 1.2, 1.6, 2.0, 2.5, 3.0, 3.5]
    /// Offsets sideways, metres, negative left.
    static let laterals: [Float] = stride(from: Float(-1.5), through: 1.5, by: 0.25).map { $0 }

    /// Row-major: `alongs.count` rows of `laterals.count`; nil where the point is out of view.
    let kinds: [SurfaceKind?]
    /// Whether the scene looks like outdoors (`SurfaceMap.looksOutdoors`).
    let isOutdoors: Bool
    /// The segmentation the layout was read from, so two layouts can be told apart as two reads.
    let generation: Int

    /// - Parameter sample: the surface `along` metres ahead and `lateral` metres to the side.
    init(isOutdoors: Bool, generation: Int, sample: (_ along: Float, _ lateral: Float) -> SurfaceKind?) {
        self.isOutdoors = isOutdoors
        self.generation = generation
        var kinds: [SurfaceKind?] = []
        kinds.reserveCapacity(Self.alongs.count * Self.laterals.count)
        for along in Self.alongs {
            for lateral in Self.laterals { kinds.append(sample(along, lateral)) }
        }
        self.kinds = kinds
    }

    /// Share of the seen cells in the box that are `kind`, and how many cells were seen.
    func share(of kind: SurfaceKind, along: ClosedRange<Float>, lateral: ClosedRange<Float>) -> (share: Float, seen: Int) {
        var seen = 0, matching = 0
        for (row, a) in Self.alongs.enumerated() where along.contains(a) {
            for (column, l) in Self.laterals.enumerated() where lateral.contains(l) {
                guard let cell = kinds[row * Self.laterals.count + column] else { continue }
                seen += 1
                if cell == kind { matching += 1 }
            }
        }
        return (seen > 0 ? Float(matching) / Float(seen) : 0, seen)
    }

    /// The nearest distance ahead at which `kind` covers the walking lane, or nil.
    func firstDistance(of kind: SurfaceKind, lane: ClosedRange<Float>, minimumShare: Float) -> Float? {
        Self.alongs.first { along in
            let (share, seen) = self.share(of: kind, along: along ... along, lateral: lane)
            return seen > 0 && share >= minimumShare
        }
    }
}

/// Where the user is relative to the sidewalk.
enum SidewalkSituation: Equatable, Sendable {
    /// On the sidewalk with nothing to say.
    case onSidewalk
    /// On the sidewalk, with road starting this close (metres) to the walking line on `side`.
    case roadBeside(TurnSide, edge: Float)
    /// Road underfoot; the sidewalk, if one is seen, is on `sidewalkSide`.
    case inRoad(sidewalkSide: TurnSide?)
    /// The sidewalk ends this far ahead, with road beyond.
    case curbAhead(distance: Float)
    /// Indoors, on grass or a path, or not enough seen.
    case unknown
}

/// Knobs for `assessSidewalk`, in metres.
struct SidewalkTuning: Sendable {
    /// Half the walking lane's width.
    var laneHalfWidth: Float = 0.45
    /// What counts as underfoot.
    var near: ClosedRange<Float> = 0.8 ... 1.6
    /// Where the sidewalk ending is looked for.
    var ahead: ClosedRange<Float> = 2.0 ... 3.5
    /// Road starting within this of the walking line counts as close.
    var closeEdge: Float = 1.0
    /// Share of the seen cells a surface needs to count as there.
    var minimumShare: Float = 0.6
    /// Fewer seen cells than this and nothing is decided.
    var minimumSeen = 4

    static let `default` = SidewalkTuning()

    init() {}
}

/// Reads a layout: on the sidewalk, near its edge, off it, or at its end.
func assessSidewalk(_ layout: GroundLayout, tuning: SidewalkTuning = .default) -> SidewalkSituation {
    guard layout.isOutdoors else { return .unknown }
    let lane = -tuning.laneHalfWidth ... tuning.laneHalfWidth
    let leftBand = -1.5 ... -tuning.laneHalfWidth - 0.05
    let rightBand = tuning.laneHalfWidth + 0.05 ... 1.5

    func isMostly(_ kind: SurfaceKind, along: ClosedRange<Float>, lateral: ClosedRange<Float>, share: Float? = nil) -> Bool {
        let reading = layout.share(of: kind, along: along, lateral: lateral)
        return reading.seen >= tuning.minimumSeen && reading.share >= (share ?? tuning.minimumShare)
    }

    if isMostly(.road, along: tuning.near, lateral: lane) {
        let left = layout.share(of: .pavement, along: tuning.near, lateral: leftBand)
        let right = layout.share(of: .pavement, along: tuning.near, lateral: rightBand)
        let side: TurnSide? = switch (left.share >= 0.4 && left.seen >= 2, right.share >= 0.4 && right.seen >= 2) {
        case (true, false): .left
        case (false, true): .right
        case (true, true): left.share >= right.share ? .left : .right
        case (false, false): nil
        }
        return .inRoad(sidewalkSide: side)
    }

    guard isMostly(.pavement, along: tuning.near, lateral: lane, share: 0.5) else { return .unknown }

    if isMostly(.road, along: tuning.ahead, lateral: lane),
       let distance = layout.firstDistance(of: .road, lane: lane, minimumShare: 0.5) {
        return .curbAhead(distance: distance)
    }

    // The closest lateral offset, either side, where road takes over beside the lane.
    func edge(on side: TurnSide) -> Float? {
        let offsets = GroundLayout.laterals.filter { side == .left ? $0 < -tuning.laneHalfWidth : $0 > tuning.laneHalfWidth }
            .sorted { abs($0) < abs($1) }
        return offsets.first { offset in
            isMostly(.road, along: tuning.near.lowerBound ... 2.0, lateral: offset ... offset, share: 0.5)
        }.map(abs)
    }
    let left = edge(on: .left), right = edge(on: .right)
    switch (left, right) {
    case let (l?, r?):
        let nearer: (TurnSide, Float) = l <= r ? (.left, l) : (.right, r)
        if nearer.1 <= tuning.closeEdge { return .roadBeside(nearer.0, edge: nearer.1) }
    case let (l?, nil) where l <= tuning.closeEdge:
        return .roadBeside(.left, edge: l)
    case let (nil, r?) where r <= tuning.closeEdge:
        return .roadBeside(.right, edge: r)
    default:
        break
    }
    return .onSidewalk
}

/// Turns sidewalk situations into announcements, once confirmed and not too often.
struct SidewalkGuide: Sendable {
    /// Separate segmentations that must agree before anything is said.
    var confirmations = 2
    /// "Road close on your right" is not repeated for this long.
    var edgeRepeatInterval: TimeInterval = 15
    /// "You may be in the road" repeats this often while it lasts.
    var inRoadRepeatInterval: TimeInterval = 6
    var curbRepeatInterval: TimeInterval = 15
    var announcementLifetime: TimeInterval = 2

    /// The confirmed situation, for the developer readout.
    private(set) var current: SidewalkSituation = .unknown
    private var candidate: SidewalkSituation?
    private var seenIn: Set<Int> = []
    private var lastSpoken: [String: TimeInterval] = [:]

    init() {}

    /// - Parameter isCrossing: a crosswalk was seen in the last few seconds. Being in the road
    ///   is then the point, and "You may be in the road" is not said.
    mutating func announcements(
        for layout: GroundLayout?, isCrossing: Bool = false, at time: TimeInterval, now: Date = .now
    ) -> [AnnouncementEvent] {
        guard let layout else {
            candidate = nil
            seenIn = []
            current = .unknown
            return []
        }
        let situation = assessSidewalk(layout)
        // Confirm the kind of situation, not its exact edge distance, which wobbles.
        if candidate.map({ Self.key(of: $0) }) != Self.key(of: situation) {
            candidate = situation
            seenIn = []
        }
        candidate = situation
        seenIn.insert(layout.generation)
        guard seenIn.count >= confirmations else { return [] }
        current = situation

        let key = Self.key(of: situation)
        let text: String
        let haptic: HapticID
        let priority: AnnouncementPriority
        let repeatInterval: TimeInterval
        switch situation {
        case .onSidewalk, .unknown:
            return []
        case let .roadBeside(side, _):
            text = "Road close on your \(side.rawValue). Keep \(side == .left ? "right" : "left")."
            haptic = side == .left ? .turnRight : .turnLeft
            priority = .high
            repeatInterval = edgeRepeatInterval
        case let .inRoad(sidewalkSide):
            guard !isCrossing else { return [] }
            text = sidewalkSide.map { "You may be in the road. Sidewalk on your \($0.rawValue)." }
                ?? "You may be in the road."
            haptic = switch sidewalkSide {
            case .left: .turnLeft
            case .right: .turnRight
            case nil: .attention
            }
            priority = .high
            repeatInterval = inRoadRepeatInterval
        case let .curbAhead(distance):
            text = "Curb ahead, \(SpokenPhrasing.distance(Double(distance))). Road beyond."
            haptic = .attention
            priority = .high
            repeatInterval = curbRepeatInterval
        }
        guard time - (lastSpoken[key] ?? -.infinity) >= repeatInterval else { return [] }
        lastSpoken[key] = time
        return [AnnouncementEvent(
            category: .hazard,
            priority: priority,
            text: text,
            haptic: haptic,
            bearing: .ahead,
            source: .obstacleDetection,
            createdAt: now,
            expiresAt: now.addingTimeInterval(announcementLifetime),
            dedupKey: "sidewalk-\(key)"
        )]
    }

    private static func key(of situation: SidewalkSituation) -> String {
        switch situation {
        case .onSidewalk: "on"
        case let .roadBeside(side, _): "edge-\(side.rawValue)"
        case let .inRoad(side): "road-\(side?.rawValue ?? "none")"
        case .curbAhead: "curb"
        case .unknown: "unknown"
        }
    }
}
