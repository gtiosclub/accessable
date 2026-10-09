import Foundation

// Kerbs, steps and drop-offs (1.1 / task T12).
//
// Unlike T11 this is about the GROUND changing height, not an object standing on it.
// Input is a height profile straight ahead of the user; output is the places that profile
// changes abruptly enough to matter.

/// Knobs for `detectElevationHazards`, in metres unless noted.
struct ElevationTuning: Sendable {
    /// Width of the distance buckets the raw samples are collapsed into.
    var binWidth: Float = 0.10
    /// Below this, a height change is depth noise rather than a step. 0.05 m sits above
    /// LiDAR noise at a few metres while still catching a low kerb.
    var minStepHeight: Float = 0.05
    /// A fall of at least this much is a `.dropOff` rather than a `.stepDown`.
    /// Kerbs are 0.10-0.15 m and code-limited stair risers top out near 0.19 m, so
    /// anything past 0.25 m is not a step a person can take — it is a fall risk, and it
    /// needs a more urgent announcement.
    var dropOffHeight: Float = 0.25
    /// Minimum rise-over-run for a change to count as a step. A compliant 1:12 ramp is
    /// 0.083 and a pavement cross-fall is gentler still; 0.25 (about 14 degrees) is far
    /// too steep to walk up as a slope, so it behaves like a step. This is what separates
    /// a ramp from a kerb.
    var rampMaxSlope: Float = 0.25
    /// Consecutive same-direction changes within this run are merged into one step, so
    /// noise cannot split one 0.18 m drop into two 0.09 m ones.
    var stepMaxRun: Float = 0.30
    /// Median filter width, in bins. 3 kills a single-bin outlier that survived binning
    /// without smearing a real 0.10 m edge across 0.30 m of distance.
    var smoothingWindow: Int = 3
    /// Absolute floor on what counts as a hole in coverage. The effective threshold also
    /// scales with the observed sample spacing — see `detectElevationHazards`.
    var maxSampleGap: Float = 0.40
    /// Never report two hazards closer together than this.
    var minHazardSpacing: Float = 0.15
    /// How far the depth sensor was expected to return data, if the caller knows. When
    /// set, coverage that simply stops short of it is reported as a `.dropOff`: a kerb
    /// edge often returns NO depth at all beyond it, so absent data is itself the signal.
    /// Left nil because a bare height profile carries no sensor range to infer it from.
    var expectedMaxDistance: Float?

    static let `default` = ElevationTuning()

    init() {}
}

/// Finds height changes in a forward ground profile and classifies them.
///
/// Returns hazards sorted by distance, nearest first.
func detectElevationHazards(
    samples: [GroundSample],
    tuning: ElevationTuning = .default
) -> [ElevationHazard] {
    // 1. Drop holes in the depth data, then put the profile in order.
    let usable = samples
        .filter { $0.forwardDistance.isFinite && $0.height.isFinite }
        .sorted { $0.forwardDistance < $1.forwardDistance }
    guard usable.count >= 2 else { return [] }

    // 2. Collapse into distance bins, taking the MEDIAN height of each. Median, not mean:
    // depth maps throw isolated spikes (a puddle, a sensor flyer) and a single spike moves
    // a mean far enough to invent a step that isn't there.
    var buckets: [Int: [GroundSample]] = [:]
    for sample in usable {
        buckets[Int((sample.forwardDistance / tuning.binWidth).rounded(.down)), default: []].append(sample)
    }
    var distances: [Float] = []
    var heights: [Float] = []
    for index in buckets.keys.sorted() {
        let bucket = buckets[index]!
        distances.append(bucket.reduce(0) { $0 + $1.forwardDistance } / Float(bucket.count))
        heights.append(median(bucket.map(\.height)))
    }
    guard distances.count >= 2 else { return [] }

    // 3. Median-smooth the binned profile. A median filter is edge-preserving, so a real
    // step survives it while speckle does not.
    heights = medianSmoothed(heights, window: tuning.smoothingWindow)

    // A "gap" has to be judged against how densely this profile was actually sampled: a
    // 0.5 m spacing is normal for a sparse profile and a hole for a dense one. Scale off
    // the median spacing, with `maxSampleGap` as the absolute floor.
    var spacings: [Float] = []
    for index in 1 ..< distances.count {
        spacings.append(distances[index] - distances[index - 1])
    }
    let gapThreshold = max(tuning.maxSampleGap, 3 * median(spacings))

    // Split into runs of continuous coverage. Step detection happens inside a segment
    // only; a height change across a hole cannot be attributed to a step.
    var segments: [Range<Int>] = []
    var segmentStart = 0
    for index in 1 ..< distances.count where distances[index] - distances[index - 1] > gapThreshold {
        segments.append(segmentStart ..< index)
        segmentStart = index
    }
    segments.append(segmentStart ..< distances.count)

    var hazards: [ElevationHazard] = []

    for (segmentIndex, segment) in segments.enumerated() {
        // 4. Walk the segment, accumulating consecutive same-direction changes.
        var index = segment.lowerBound
        while index < segment.upperBound - 1 {
            let start = index
            var end = index + 1
            let rising = heights[end] - heights[start] >= 0

            // Extend the run while it keeps going the same way and stays short enough to
            // be one physical step. A single interval is always allowed, however long —
            // otherwise a sparsely sampled profile could never report a step at all.
            while end + 1 < segment.upperBound {
                let nextDelta = heights[end + 1] - heights[end]
                guard nextDelta != 0, (nextDelta >= 0) == rising else { break }
                // Epsilon so a run landing exactly on the limit isn't rejected by float noise.
                guard distances[end + 1] - distances[start] <= tuning.stepMaxRun + 1e-4 else { break }
                end += 1
            }

            let heightChange = heights[end] - heights[start]
            let run = max(distances[end] - distances[start], 1e-4)

            // 5. A step needs both enough height AND enough steepness. The height test
            // alone would flag a long gentle ramp; the slope test alone would flag noise.
            if abs(heightChange) >= tuning.minStepHeight,
               abs(heightChange) / run >= tuning.rampMaxSlope {
                let type: ElevationHazardType = if heightChange > 0 {
                    .stepUp
                } else if abs(heightChange) >= tuning.dropOffHeight {
                    .dropOff
                } else {
                    .stepDown
                }
                hazards.append(
                    ElevationHazard(type: type, distance: distances[start], heightChange: heightChange)
                )
            }

            index = end
        }

        // 6. Coverage gaps. An interior hole is genuinely ambiguous, so say so rather
        // than guessing at a height.
        let isLastSegment = segmentIndex == segments.count - 1
        if !isLastSegment {
            hazards.append(
                ElevationHazard(type: .unknown, distance: distances[segment.upperBound - 1], heightChange: 0)
            )
        } else if let expected = tuning.expectedMaxDistance {
            // Dense coverage that simply stops is the classic drop-off signature: there
            // is nothing past the edge for the sensor to bounce off. heightChange stays 0
            // because the depth of the drop is exactly what we cannot see.
            let lastDistance = distances[segment.upperBound - 1]
            if lastDistance < expected - gapThreshold {
                hazards.append(ElevationHazard(type: .dropOff, distance: lastDistance, heightChange: 0))
            }
        }
    }

    // 7. Thin out hazards that sit on top of each other, then report nearest first.
    var result: [ElevationHazard] = []
    for hazard in hazards.sorted(by: { $0.distance < $1.distance }) {
        if let previous = result.last, hazard.distance - previous.distance < tuning.minHazardSpacing {
            continue
        }
        result.append(hazard)
    }
    return result
}

// A flight of stairs reports one hazard per riser. That is deliberate: this detector stays
// faithful to what it measured, and collapsing N same-direction steps into "stairs ahead"
// is a phrasing decision for the scene description (1.3) and the announcement engine
// (3.3), which already has `GroundSurface.stairs` to say it with.

/// Median of `values`, taking the lower of the two middle elements for an even count.
/// Returns 0 when empty, which only happens on inputs already rejected by the caller.
///
/// Lower-median rather than the usual average-of-two, because every use of this is meant
/// to preserve edges. A bin straddling a kerb holds one height from each side, and
/// averaging them reports half a kerb twice instead of one kerb — which is exactly the
/// failure a step detector must not have. Taking an actual sample keeps the edge intact,
/// and erring low means a drop is reported from the nearer bin.
func median(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? sorted[middle - 1] : sorted[middle]
}

/// Sliding median over `values`. Windows are clipped at the ends rather than padded, so
/// the first and last entries keep their measured values.
func medianSmoothed(_ values: [Float], window: Int) -> [Float] {
    guard window > 1, values.count > window else { return values }
    let half = window / 2
    return values.indices.map { index in
        // A clipped window at the ends would average a real edge away — the last bin of a
        // profile that drops off a kerb is exactly the value we must not soften.
        guard index - half >= 0, index + half < values.count else { return values[index] }
        return median(Array(values[(index - half) ... (index + half)]))
    }
}
