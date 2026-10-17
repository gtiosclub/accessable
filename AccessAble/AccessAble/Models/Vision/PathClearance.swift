import Foundation
import simd

// Finding the way past what is in the walking corridor (1.1, "local safe-path guidance").
//
// Works on the `LocalOccupancyMap`, not on this frame's detections, so the answer is as
// steady as the map: a wall seen two seconds ago still counts, and a flicker in one frame
// changes nothing. The question asked of the map is simple and the same for every option
// considered: how far can the user walk straight along this line before hitting something?

/// A side to turn towards when nothing ahead is passable.
enum TurnSide: String, Codable, Sendable {
    case left, right
}

/// Which way the user should go.
enum ClearDirection: String, Codable, Sendable {
    /// Nothing within reach blocks the corridor.
    case ahead
    /// The corridor is blocked; the nearest usable gap is to the left.
    case left
    /// The corridor is blocked; the nearest usable gap is to the right.
    case right
    /// The corridor is blocked and no sidestep helps. Stop and turn.
    case blocked
}

/// Knobs for `planPath`, in metres.
struct PathClearanceTuning: Sendable {
    /// How far ahead a line must be free to count as clear.
    var lookAhead: Float = 3.0
    /// A sidestep is offered when the corridor ahead is blocked within this distance.
    var blockedWithin: Float = 2.5
    /// Lateral offsets tried either side of the centre line, and their spacing.
    var maximumSidestep: Float = 1.5
    var sidestepSpacing: Float = 0.1
    /// A sidestep must buy at least this much more free distance than straight ahead…
    var minimumGain: Float = 0.6
    /// …and must be free for at least this far to be worth taking.
    var minimumFreeRun: Float = 1.5
    /// Headings tried when no sidestep helps, in degrees, nearest turn first.
    var turnAngles: [Float] = [60, -60, 120, -120, 180]
    /// A turn is suggested when that heading is free for at least this far.
    var minimumTurnRun: Float = 1.5
    /// A sidestep is only offered into space that has been seen: at least this fraction of
    /// the cells along the new line, as far as the obstacle, must be known free. Unknown
    /// cells count as passable when measuring runs, but the user is not sent into the
    /// unknown — they are asked to turn instead, and the scan fills the map in.
    var minimumKnownFree: Float = 0.4
    /// Lateral spacing of the cells checked across the corridor's width.
    var sampleSpacing: Float = 0.1
    /// Where along the line checking starts: the nearest cells hold the user.
    var start: Float = 0.3

    static let `default` = PathClearanceTuning()

    init() {}
}

/// Where the open space is.
struct PathAssessment: Equatable, Sendable {
    var clearDirection: ClearDirection
    /// Lateral offset, in metres, of the recommended line of travel: negative left. Zero
    /// when the path ahead is clear; nil when blocked.
    var sidestep: Float?
    /// True when the recommended line is only just wide enough.
    var isNarrow = false
    /// When blocked: the side with more room to turn towards, if one could be told.
    var turn: TurnSide?
    /// Distance along the centre line to the first occupied cell; nil when the corridor is
    /// free for the whole look-ahead.
    var blockedDistance: Float?

    /// The path ahead is open.
    static let clear = PathAssessment(clearDirection: .ahead, sidestep: 0)
    /// The corridor is blocked with no visible way round.
    static let blocked = PathAssessment(clearDirection: .blocked, sidestep: nil)
}

/// Reads the map along the user's heading and decides: carry on, step aside, or turn.
///
/// - Parameters:
///   - map: The accumulated occupancy map.
///   - heading: The user's level heading: origin at the camera, `forward` along the
///     ground, `right` level (a flattened `WalkingCorridor`). Its width is the corridor.
func planPath(
    map: LocalOccupancyMap,
    heading: WalkingCorridor,
    tuning: PathClearanceTuning = .default
) -> PathAssessment {
    let origin = SIMD2(heading.origin.x, heading.origin.z)
    let forward = simd_normalize(SIMD2(heading.forward.x, heading.forward.z))
    let right = simd_normalize(SIMD2(heading.right.x, heading.right.z))
    guard forward.x.isFinite, forward.y.isFinite, right.x.isFinite, right.y.isFinite else { return .clear }
    let width = heading.width

    func lane(offset: Float, forward: SIMD2<Float>, right: SIMD2<Float>, evidenceTo: Float) -> LaneReading {
        readLane(
            map: map, origin: origin + right * offset, forward: forward, right: right,
            width: width, evidenceTo: evidenceTo, tuning: tuning
        )
    }

    let straight = lane(offset: 0, forward: forward, right: right, evidenceTo: tuning.lookAhead).freeRun
    let blockedDistance: Float? = straight < tuning.lookAhead ? straight : nil
    guard let blockedDistance, blockedDistance <= tuning.blockedWithin else {
        return PathAssessment(clearDirection: .ahead, sidestep: 0, blockedDistance: blockedDistance)
    }

    // Sidesteps, nearest the centre line first so ties go to the smallest step.
    var best: (offset: Float, run: Float)?
    var offset = tuning.sidestepSpacing
    while offset <= tuning.maximumSidestep + 1e-4 {
        for signed in [-offset, offset] {
            let reading = lane(offset: signed, forward: forward, right: right, evidenceTo: blockedDistance)
            if reading.freeRun >= straight + tuning.minimumGain, reading.freeRun >= tuning.minimumFreeRun,
               reading.knownFreeFraction >= tuning.minimumKnownFree, reading.freeRun > (best?.run ?? 0) {
                best = (signed, reading.freeRun)
            }
        }
        // A long enough run close by beats a slightly longer one further out.
        if let best, best.run >= tuning.lookAhead { break }
        offset += tuning.sidestepSpacing
    }
    if let best {
        return PathAssessment(
            clearDirection: best.offset < 0 ? .left : .right,
            sidestep: best.offset,
            isNarrow: false,
            blockedDistance: blockedDistance
        )
    }

    // Nothing to the side either: which way to turn. Turning may point at unknown space —
    // that is how it gets seen — but a direction already known to be open is preferred.
    var blocked = PathAssessment.blocked
    blocked.blockedDistance = blockedDistance
    var bestTurn: (degrees: Float, known: Float)?
    for degrees in tuning.turnAngles {
        let radians = degrees * .pi / 180
        // Positive degrees turn right: rotate forward towards right.
        let turnedForward = forward * cos(radians) + right * sin(radians)
        let turnedRight = right * cos(radians) - forward * sin(radians)
        let reading = lane(offset: 0, forward: turnedForward, right: turnedRight, evidenceTo: tuning.minimumTurnRun)
        guard reading.freeRun >= tuning.minimumTurnRun else { continue }
        if reading.knownFreeFraction > (bestTurn?.known ?? -1) {
            bestTurn = (degrees, reading.knownFreeFraction)
        }
    }
    if let bestTurn { blocked.turn = bestTurn.degrees < 0 ? .left : .right }
    return blocked
}

/// What the map says along one line of travel.
struct LaneReading: Equatable, Sendable {
    /// How far the lane stays free of occupied cells, up to the look-ahead. Unknown cells
    /// count as free: the map only ever blocks on evidence.
    var freeRun: Float
    /// Fraction of the lane's cells, as far as `evidenceTo`, that have been seen free.
    var knownFreeFraction: Float
}

/// Reads a corridor `width` wide along `forward` from `origin`.
func readLane(
    map: LocalOccupancyMap,
    origin: SIMD2<Float>,
    forward: SIMD2<Float>,
    right: SIMD2<Float>,
    width: Float,
    evidenceTo: Float,
    tuning: PathClearanceTuning = .default
) -> LaneReading {
    let halfWidth = width / 2
    var lateral: [Float] = []
    var l = -halfWidth
    while l <= halfWidth + 1e-4 {
        lateral.append(l)
        l += tuning.sampleSpacing
    }

    var sampled = 0
    var knownFree = 0
    var freeRun = tuning.lookAhead
    var distance = tuning.start
    scan: while distance < tuning.lookAhead {
        let centre = origin + forward * distance
        for offset in lateral {
            let cell = centre + right * offset
            if map.isOccupied(x: cell.x, z: cell.y) {
                freeRun = distance
                break scan
            }
            if distance <= evidenceTo {
                sampled += 1
                if map.isKnownFree(x: cell.x, z: cell.y) { knownFree += 1 }
            }
        }
        distance += map.tuning.cellSize * 0.5
    }
    return LaneReading(freeRun: freeRun, knownFreeFraction: sampled > 0 ? Float(knownFree) / Float(sampled) : 0)
}
