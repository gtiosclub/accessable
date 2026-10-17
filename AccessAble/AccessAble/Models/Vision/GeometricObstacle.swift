import Foundation
import simd

/// Something standing up off the floor, found by geometry alone — no object-recognition
/// label involved, so it catches the things a model has never seen.
/// Owner: Computer Vision (1.1 / task T11).
struct GeometricObstacle: Identifiable, Sendable {
    let id: UUID
    /// Centroid of the supporting points, in the input cloud's coordinate space (metres).
    let center: SIMD3<Float>
    /// Straight-line distance in metres from `corridor.origin` to the nearest supporting
    /// point. This is the distance to announce — not the distance along the path.
    let nearestDistance: Float
    /// Extent along the corridor's lateral axis, in metres. Corridor-relative, not a
    /// world axis-aligned box, so it answers "how much of my way does this block".
    let width: Float
    /// Height above the floor plane of the highest supporting point, in metres. The top
    /// of the object, not the vertical extent of the points — an overhanging sign reports
    /// the height you would hit it at.
    let height: Float
    /// True when any supporting point falls inside the corridor. False obstacles are
    /// still returned, so callers can keep tracking something about to cut in.
    let intersectsWalkingCorridor: Bool
    /// Where the obstacle sits across the path: its extent along the corridor's lateral
    /// axis in metres, negative to the user's left of the centre line. This is what the
    /// clearance search (`assessPath`) works from.
    let lateralRange: ClosedRange<Float>
    /// Its extent along the corridor's forward axis, in metres ahead of the origin.
    let forwardRange: ClosedRange<Float>

    init(
        id: UUID = UUID(),
        center: SIMD3<Float>,
        nearestDistance: Float,
        width: Float,
        height: Float,
        intersectsWalkingCorridor: Bool,
        lateralRange: ClosedRange<Float>? = nil,
        forwardRange: ClosedRange<Float>? = nil
    ) {
        self.id = id
        self.center = center
        self.nearestDistance = nearestDistance
        self.width = width
        self.height = height
        self.intersectsWalkingCorridor = intersectsWalkingCorridor
        self.lateralRange = lateralRange ?? (-width / 2 ... width / 2)
        self.forwardRange = forwardRange ?? (nearestDistance ... nearestDistance)
    }
}

extension GeometricObstacle {
    /// What to call an obstacle nothing has recognized. Chosen from its shape, so the user
    /// hears "wall" or "pole" instead of a generic "obstacle" wherever the geometry allows.
    enum Kind: String, CaseIterable, Sendable {
        /// Wide and tall: a wall, fence, parked vehicle, shutter. Not something to go around
        /// by a step — the user needs to turn.
        case wall
        /// Tall and thin: a post, bollard, lamp post, tree trunk.
        case pole
        /// Below knee height: a kerb stone, box, step of a plinth. A trip hazard rather
        /// than something to walk into.
        case lowObstacle = "low obstacle"
        case obstacle

        /// The label spoken and shown for an obstacle of this kind.
        var label: String { rawValue }
    }

    /// Thresholds for `kind(coverage:)`, in metres.
    struct Classification: Sendable {
        /// Anything whose top is below this is a low obstacle.
        var lowHeight: Float = 0.5
        /// A pole must reach this high…
        var poleMinimumHeight: Float = 1.4
        /// …and be no wider than this.
        var poleMaximumWidth: Float = 0.35
        /// A wall must reach this high…
        var wallMinimumHeight: Float = 1.0
        /// …and be at least this wide, or span everything the sensor could see sideways.
        var wallMinimumWidth: Float = 1.5
        /// An obstacle whose edge is this close to the edge of the sensed region is taken
        /// to continue beyond it.
        var coverageEdgeMargin: Float = 0.08

        static let `default` = Classification()

        init() {}
    }

    /// Classifies the obstacle by shape. `coverage` is the lateral extent the depth sensor
    /// actually observed at this range (see `lateralCoverage`); an obstacle that fills it
    /// edge to edge is a wall even when the visible part is narrow, as it is up close.
    func kind(coverage: ClosedRange<Float>?, rules: Classification = .default) -> Kind {
        if height < rules.lowHeight { return .lowObstacle }
        if height >= rules.poleMinimumHeight, width <= rules.poleMaximumWidth { return .pole }
        if height >= rules.wallMinimumHeight {
            if width >= rules.wallMinimumWidth { return .wall }
            if let coverage, spansCoverage(coverage, margin: rules.coverageEdgeMargin) { return .wall }
        }
        return .obstacle
    }

    /// Whether the obstacle reaches the left edge of what the sensor saw, so it may well
    /// continue further left than measured.
    func reachesLeftEdge(of coverage: ClosedRange<Float>, margin: Float) -> Bool {
        lateralRange.lowerBound - coverage.lowerBound <= margin
    }

    /// The right-hand counterpart of `reachesLeftEdge`.
    func reachesRightEdge(of coverage: ClosedRange<Float>, margin: Float) -> Bool {
        coverage.upperBound - lateralRange.upperBound <= margin
    }

    private func spansCoverage(_ coverage: ClosedRange<Float>, margin: Float) -> Bool {
        reachesLeftEdge(of: coverage, margin: margin) && reachesRightEdge(of: coverage, margin: margin)
    }
}
