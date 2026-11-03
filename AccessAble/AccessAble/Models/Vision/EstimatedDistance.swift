import Foundation

// Turning the T33 estimates into one distance the rest of the pipeline can use (1.1 / task T33).

/// One distance for a detection, with how far it can be trusted.
struct EstimatedDistance: Equatable, Sendable {
    let meters: Double
    let accuracy: DistanceAccuracy
}

/// Combines a floor-contact estimate with a known-size range into one answer.
///
/// Floor contact leads: it is metric by construction and works whatever the label, including
/// for things the detector has no size prior for. The size range is a check on it.
///
/// Where the two agree, their overlap is tighter than either alone and is used. Where they
/// disagree, the uncertainty is widened to span both instead of one being picked — a
/// disagreement means at least one is wrong, and reporting that honestly is the whole point
/// of T33. Silently preferring one would produce a confident number built on a contradiction.
func combinedDistance(
    groundContact: GroundContactEstimate?,
    sizeRange: ClosedRange<Float>?,
    minimumError: Float = 0.08
) -> EstimatedDistance? {
    let contactRange: ClosedRange<Float>? = groundContact.map {
        max(0, $0.meters - $0.plusMinus) ... ($0.meters + $0.plusMinus)
    }

    let combined: ClosedRange<Float>
    switch (contactRange, sizeRange) {
    case (nil, nil):
        return nil
    case (let contact?, nil):
        combined = contact
    case (nil, let size?):
        combined = size
    case (let contact?, let size?):
        if contact.overlaps(size) {
            combined = max(contact.lowerBound, size.lowerBound) ... min(contact.upperBound, size.upperBound)
        } else {
            combined = min(contact.lowerBound, size.lowerBound) ... max(contact.upperBound, size.upperBound)
        }
    }

    let meters = (combined.lowerBound + combined.upperBound) / 2
    let plusMinus = max((combined.upperBound - combined.lowerBound) / 2, minimumError)
    guard meters.isFinite, meters > 0, plusMinus.isFinite else { return nil }
    return EstimatedDistance(meters: Double(meters), accuracy: .estimated(plusMinus: Double(plusMinus)))
}

extension Detection {
    /// The nearest distance consistent with what is known about this detection.
    ///
    /// Warnings act on this rather than on the point estimate: for someone who cannot see the
    /// obstacle, a warning that arrives early costs a moment and one that arrives late cannot
    /// be taken back. A measured distance is returned unchanged, so devices with LiDAR behave
    /// exactly as they did before T33.
    var cautiousDistance: Double? {
        guard let distance else { return nil }
        return switch distanceAccuracy {
        case .measured, .none: distance
        case .estimated(let plusMinus): max(0, distance - plusMinus)
        }
    }
}
