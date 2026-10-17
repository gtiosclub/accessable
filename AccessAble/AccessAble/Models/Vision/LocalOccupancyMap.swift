import Foundation
import simd

// A map of the floor around the user, built up frame by frame (1.1).
//
// Deciding from one frame is what made the advice flip: the LiDAR sees about ±0.5 m at
// 1 m, so what counts as "the way round" changes with every small turn of the phone. An
// occupancy map is the standard answer in robotics. ARKit's world is gravity-aligned and
// stays put while tracking runs, so every depth point can be dropped onto a grid of floor
// cells and kept. Each point says two things: the cell it lands in holds something, and
// every cell on the straight line from the camera to it does not (the laser got through).
// Evidence accumulates as log-odds, one update per cell per FRAME: a cell hit by any
// point this frame gains a hit, a cell only seen through loses one. Counting frames rather
// than points means a dense near object and a sparse far one are believed at the same
// rate, and a ray grazing the corner of an occupied cell cannot outvote the points in it.
// One speckle never makes an obstacle, one clear look never erases a wall, and the grid
// remembers the wall after the user turns away.
//
// Kerbs and drop-offs are not in here: they are changes in the floor, not things on it,
// and T12 owns them.

/// Knobs for `LocalOccupancyMap`, in metres unless noted.
struct OccupancyTuning: Sendable {
    var cellSize: Float = 0.10
    /// Cells per side. 160 × 0.1 m is a 16 m square, recentred as the user walks.
    var cellsPerSide = 160
    /// The grid is shifted to follow the camera once it strays this far from the centre.
    var recentreDistance: Float = 4.0
    /// Heights above the floor that are something to walk into. Below is floor noise and
    /// kerbs (T12); above is ceilings, door tops and signs the user walks under.
    var obstacleHeights: ClosedRange<Float> = 0.15 ... 2.0
    /// Heights that are the floor itself, and so evidence of free space where they land.
    var floorHeights: ClosedRange<Float> = -0.12 ... 0.10
    /// When the floor plane is only remembered, hits must clear this height to count, so a
    /// few centimetres of error in the plane cannot turn the floor into a wall.
    var uncertainFloorMinimumHeight: Float = 0.40
    /// Log-odds added per frame to a cell with a hit, subtracted per frame from a cell
    /// only seen through, and subtracted where the floor itself was seen. Two frames of
    /// hits make a cell occupied; a cell at the cap takes four clear frames to free.
    var hitWeight: Float = 0.85
    var missWeight: Float = 0.5
    var floorWeight: Float = 0.6
    var occupiedThreshold: Float = 1.2
    var logOddsRange: ClosedRange<Float> = -3 ... 3
    /// Rays start this far from the camera: the nearest cells hold the user's own body.
    var rayStart: Float = 0.3
    /// Rays stop marking cells free this many cells short of their end point, so a ray
    /// grazing the corner of the cell next to its hit does not count against that cell.
    var rayEndMargin: Float = 1.0

    static let `default` = OccupancyTuning()

    init() {}
}

/// A rolling grid of floor cells around the user, in ARKit's gravity-aligned world
/// (x and z), each holding the log-odds that something stands there.
struct LocalOccupancyMap: Sendable {
    let tuning: OccupancyTuning
    /// World x/z of the corner of cell (0, 0).
    private(set) var origin: SIMD2<Float>
    private var logOdds: [Float]
    private(set) var hasEvidence = false

    /// Per-frame scratch: what each cell saw this frame, folded into `logOdds` at the end.
    private enum Seen: UInt8 {
        case nothing = 0, through = 1, floor = 2, hit = 3
    }

    private var seenThisFrame: [Seen]
    private var touched: [Int] = []

    init(tuning: OccupancyTuning = .default, centre: SIMD2<Float> = .zero) {
        self.tuning = tuning
        let half = Float(tuning.cellsPerSide) * tuning.cellSize / 2
        origin = centre - SIMD2(half, half)
        logOdds = [Float](repeating: 0, count: tuning.cellsPerSide * tuning.cellsPerSide)
        seenThisFrame = [Seen](repeating: .nothing, count: logOdds.count)
    }

    /// Forget everything, e.g. when tracking restarts and world coordinates change.
    mutating func reset(centre: SIMD2<Float> = .zero) {
        self = LocalOccupancyMap(tuning: tuning, centre: centre)
    }

    // MARK: - Reading

    /// Log-odds of occupancy at a world x/z, or nil outside the grid.
    func logOdds(atX x: Float, z: Float) -> Float? {
        guard let index = index(forX: x, z: z) else { return nil }
        return logOdds[index]
    }

    /// Whether something is known to stand at a world x/z.
    func isOccupied(x: Float, z: Float) -> Bool {
        (logOdds(atX: x, z: z) ?? 0) >= tuning.occupiedThreshold
    }

    /// Whether a world x/z has been seen to be free.
    func isKnownFree(x: Float, z: Float) -> Bool {
        (logOdds(atX: x, z: z) ?? 0) < 0
    }

    // MARK: - Writing

    /// Folds one frame's point cloud into the map.
    ///
    /// - Parameters:
    ///   - points: World-space points, as `unprojectDepthMap` returns them.
    ///   - floor: The floor plane heights are measured against.
    ///   - cameraPosition: Where the rays start.
    ///   - floorIsMeasured: False when `floor` is remembered or assumed; hits then need
    ///     `uncertainFloorMinimumHeight`.
    mutating func integrate(
        points: [SIMD3<Float>],
        floor: Plane3D,
        cameraPosition: SIMD3<Float>,
        floorIsMeasured: Bool
    ) {
        let camera = SIMD2(cameraPosition.x, cameraPosition.z)
        recentreIfNeeded(around: camera)
        let minimumHit = floorIsMeasured ? tuning.obstacleHeights.lowerBound : tuning.uncertainFloorMinimumHeight

        for point in points {
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { continue }
            let height = distanceFromPlane(point: point, plane: floor)
            let target = SIMD2(point.x, point.z)

            if height >= minimumHit, height <= tuning.obstacleHeights.upperBound {
                castRay(from: camera, to: target, ending: .hit)
            } else if tuning.floorHeights.contains(height) {
                castRay(from: camera, to: target, ending: .floor)
            }
            // Above head height or below the floor: says nothing about the floor cells.
        }

        // One update per cell per frame; a hit outranks the floor, which outranks a ray.
        for index in touched {
            switch seenThisFrame[index] {
            case .hit: adjust(index, by: tuning.hitWeight)
            case .floor: adjust(index, by: -tuning.floorWeight)
            case .through: adjust(index, by: -tuning.missWeight)
            case .nothing: break
            }
            seenThisFrame[index] = .nothing
            hasEvidence = true
        }
        touched.removeAll(keepingCapacity: true)
    }

    /// Marks every cell between `from` and `to` as seen through, and the cell at `to` as
    /// `ending`, in this frame's scratch.
    private mutating func castRay(from: SIMD2<Float>, to: SIMD2<Float>, ending: Seen) {
        let delta = to - from
        let length = simd_length(delta)
        guard length > 1e-4 else { return }
        let direction = delta / length
        let step = tuning.cellSize * 0.9
        let endIndex = index(forX: to.x, z: to.y)
        var lastIndex = -1

        var distance = tuning.rayStart
        let stop = length - tuning.rayEndMargin * tuning.cellSize
        while distance < stop {
            let position = from + direction * distance
            if let index = index(forX: position.x, z: position.y), index != lastIndex, index != endIndex {
                mark(index, .through)
                lastIndex = index
            }
            distance += step
        }
        if let endIndex { mark(endIndex, ending) }
    }

    private mutating func mark(_ index: Int, _ seen: Seen) {
        let current = seenThisFrame[index]
        if current == .nothing { touched.append(index) }
        if seen.rawValue > current.rawValue { seenThisFrame[index] = seen }
    }

    private mutating func adjust(_ index: Int, by weight: Float) {
        logOdds[index] = min(max(logOdds[index] + weight, tuning.logOddsRange.lowerBound), tuning.logOddsRange.upperBound)
    }

    private func index(forX x: Float, z: Float) -> Int? {
        let column = Int(((x - origin.x) / tuning.cellSize).rounded(.down))
        let row = Int(((z - origin.y) / tuning.cellSize).rounded(.down))
        guard column >= 0, column < tuning.cellsPerSide, row >= 0, row < tuning.cellsPerSide else { return nil }
        return row * tuning.cellsPerSide + column
    }

    /// Shifts the grid so `camera` is near its centre again, keeping what overlaps.
    private mutating func recentreIfNeeded(around camera: SIMD2<Float>) {
        let half = Float(tuning.cellsPerSide) * tuning.cellSize / 2
        let centre = origin + SIMD2(half, half)
        guard simd_length(camera - centre) > tuning.recentreDistance else { return }

        let shiftColumns = Int(((camera.x - centre.x) / tuning.cellSize).rounded())
        let shiftRows = Int(((camera.y - centre.y) / tuning.cellSize).rounded())
        var shifted = [Float](repeating: 0, count: logOdds.count)
        let n = tuning.cellsPerSide
        for row in 0 ..< n {
            let sourceRow = row + shiftRows
            guard sourceRow >= 0, sourceRow < n else { continue }
            for column in 0 ..< n {
                let sourceColumn = column + shiftColumns
                guard sourceColumn >= 0, sourceColumn < n else { continue }
                shifted[row * n + column] = logOdds[sourceRow * n + sourceColumn]
            }
        }
        logOdds = shifted
        // Scratch is empty between frames, so it needs no shifting.
        origin += SIMD2(Float(shiftColumns), Float(shiftRows)) * tuning.cellSize
    }
}
