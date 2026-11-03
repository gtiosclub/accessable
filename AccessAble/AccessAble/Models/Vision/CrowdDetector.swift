import Foundation
import simd

// Grouping people into crowds (1.1 / task T35).
//
// Six people in view should not produce six sentences. One group, its count, how far away it
// starts and roughly where it lies is what a walker needs; the individuals are noise.
//
// Grouping reuses `clusterFootprints` from T11 on a floor-plane footprint. World space is
// gravity-aligned (`ARSessionManager` runs `worldAlignment = .gravity`), so dropping the
// world Y axis gives that footprint directly, with no corridor or fitted floor needed. That
// keeps crowd detection a pure function of the detections, so the description layer can call
// it without being handed the camera's geometry.
//
// Single-link clustering chains: A joins B, B joins C, C joins D. For a chair's legs and seat
// that is wanted. For people it is a trap — a queue spaced every metre and a half becomes one
// twenty-metre "crowd" whose middle has nobody standing in it. So a group spread too far in
// depth is split into bands rather than reported as one thing, and what is announced is where
// the group starts and how far it runs, never a centroid nobody occupies.

/// A group of people reported as one thing.
struct CrowdRegion: Identifiable, Equatable, Sendable {
    let id: UUID
    /// How many people were detected in the group. Approximate by nature: people occlude
    /// each other, so this is a floor on the real number rather than a count.
    let count: Int
    /// Distance to the nearest person in the group, in metres.
    let nearestDistance: Double
    /// Distance to the farthest, in metres.
    let farthestDistance: Double
    /// Direction of the nearest person, which is the one that matters for walking.
    let bearing: RelativeBearing
    /// Bearings of the leftmost and rightmost members, in degrees.
    let bearingSpan: ClosedRange<Double>
    /// Largest distance between any two members' footprints, in metres — how big the group is.
    let extent: Float
    /// Centroid in world coordinates. For the debug overlay; never spoken, because for a
    /// spread-out group it is a point with nobody on it.
    let center: SIMD3<Float>
    /// `Detection.id` of every member, so the description layer knows who not to list again.
    let memberIDs: Set<UUID>

    /// True when the group runs far enough in depth to be worth saying as a range.
    var spansDistance: Bool { farthestDistance - nearestDistance >= 1.0 }
    /// True when the group is wide enough that one direction would misrepresent it.
    var isSpreadOut: Bool { bearingSpan.upperBound - bearingSpan.lowerBound >= 45 }

    init(
        id: UUID = UUID(),
        count: Int,
        nearestDistance: Double,
        farthestDistance: Double,
        bearing: RelativeBearing,
        bearingSpan: ClosedRange<Double>,
        extent: Float,
        center: SIMD3<Float>,
        memberIDs: Set<UUID>
    ) {
        self.id = id
        self.count = count
        self.nearestDistance = nearestDistance
        self.farthestDistance = farthestDistance
        self.bearing = bearing
        self.bearingSpan = bearingSpan
        self.extent = extent
        self.center = center
        self.memberIDs = memberIDs
    }
}

/// What `detectCrowds` found.
struct CrowdDetection: Equatable, Sendable {
    /// Groups, nearest first.
    let crowds: [CrowdRegion]
    /// People in no group, still worth describing one by one.
    let ungrouped: [Detection]

    /// Every detection folded into a group.
    var groupedIDs: Set<UUID> { crowds.reduce(into: Set()) { $0.formUnion($1.memberIDs) } }
}

/// Knobs for `detectCrowds`.
struct CrowdTuning: Sendable {
    /// People within this of each other on the floor belong to the same group, in metres.
    /// Conversational spacing is under a metre; two metres still links a queue while keeping
    /// two separate knots of people across a plaza apart.
    var linkRadius: Float = 2.0
    /// Fewer than this many people is not a crowd. Two people are worth naming individually,
    /// and calling them a group loses more than it saves.
    var minimumCount: Int = 3
    /// A group running further than this in depth is split into bands of roughly this size.
    /// Reporting a queue alongside the user as one distant crowd would point at its middle,
    /// where nobody is standing.
    var maximumDepthSpan: Double = 4.0
    /// Ignore people beyond this, in metres: counting a crowd at the far end of a street is
    /// not useful and the distances out there are not trustworthy.
    var maximumDistance: Double = 12

    static let `default` = CrowdTuning()

    init() {}
}

/// Groups nearby people into crowds.
///
/// - Parameter people: Detections to consider. Anything that is not a person, or has no
///   world position or distance, goes straight to `ungrouped` — there is nothing to cluster
///   on, and it still deserves describing.
/// - Returns: Groups nearest first, plus everyone left over.
func detectCrowds(among people: [Detection], tuning: CrowdTuning = .default) -> CrowdDetection {
    var candidates: [Detection] = []
    var ungrouped: [Detection] = []
    for person in people {
        guard person.label.lowercased() == "person",
              let position = person.worldPosition,
              let distance = person.distance,
              position.x.isFinite, position.z.isFinite,
              distance.isFinite, distance <= tuning.maximumDistance
        else {
            ungrouped.append(person)
            continue
        }
        candidates.append(person)
    }

    guard candidates.count >= tuning.minimumCount else {
        return CrowdDetection(crowds: [], ungrouped: ungrouped + candidates)
    }

    // World Y is up, so x/z is the floor footprint.
    let footprints = candidates.map { SIMD2<Float>($0.worldPosition!.x, $0.worldPosition!.z) }
    var crowds: [CrowdRegion] = []

    for cluster in clusterFootprints(footprints, radius: tuning.linkRadius) {
        let members = cluster.map { candidates[$0] }
        guard members.count >= tuning.minimumCount else {
            ungrouped.append(contentsOf: members)
            continue
        }
        for band in depthBands(of: members, maximumSpan: tuning.maximumDepthSpan) {
            if band.count >= tuning.minimumCount, let region = region(of: band) {
                crowds.append(region)
            } else {
                ungrouped.append(contentsOf: band)
            }
        }
    }

    crowds.sort { $0.nearestDistance < $1.nearestDistance }
    return CrowdDetection(crowds: crowds, ungrouped: ungrouped)
}

/// Splits a group that runs too deep into consecutive bands by distance from the user.
///
/// A group spread sideways at one distance is left whole — "people from your left to your
/// right, four metres away" is a true description. Only depth is split, because that is what
/// makes a single distance a lie.
private func depthBands(of members: [Detection], maximumSpan: Double) -> [[Detection]] {
    let sorted = members.sorted { ($0.distance ?? 0) < ($1.distance ?? 0) }
    guard let first = sorted.first?.distance, let last = sorted.last?.distance,
          last - first > maximumSpan
    else { return [sorted] }

    var bands: [[Detection]] = []
    var current: [Detection] = []
    var bandStart = first
    for person in sorted {
        let distance = person.distance ?? bandStart
        if !current.isEmpty, distance - bandStart > maximumSpan {
            bands.append(current)
            current = []
            bandStart = distance
        }
        current.append(person)
    }
    if !current.isEmpty { bands.append(current) }
    return bands
}

private func region(of members: [Detection]) -> CrowdRegion? {
    let distances = members.compactMap(\.distance)
    guard let nearest = distances.min(), let farthest = distances.max(),
          let closest = members.min(by: { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) })
    else { return nil }

    let bearings = members.compactMap { $0.bearing?.degrees }
    // The camera's field of view is well under 180°, so bearings never wrap and plain
    // min/max is a correct span.
    let span = (bearings.min() ?? 0) ... (bearings.max() ?? 0)

    let positions = members.compactMap(\.worldPosition)
    guard !positions.isEmpty else { return nil }
    var centroid = SIMD3<Float>(repeating: 0)
    for position in positions { centroid += position }
    centroid /= Float(positions.count)

    var extent: Float = 0
    for (index, a) in positions.enumerated() {
        for b in positions[(index + 1)...] {
            extent = max(extent, simd_length(SIMD2(a.x - b.x, a.z - b.z)))
        }
    }

    return CrowdRegion(
        count: members.count,
        nearestDistance: nearest,
        farthestDistance: farthest,
        bearing: closest.bearing ?? .ahead,
        bearingSpan: span,
        extent: extent,
        center: centroid,
        memberIDs: Set(members.map(\.id))
    )
}
