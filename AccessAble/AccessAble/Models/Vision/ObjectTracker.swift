import CoreGraphics
import Foundation

/// Gives detections stable identities across frames. Owner: Computer Vision (1.1 / task T15).
///
/// Each frame's detections are matched to existing tracks by label and box overlap; matched
/// detections inherit the track's ID in `Detection.trackID`, unmatched ones start new
/// tracks, and tracks not seen for `maximumAge` are dropped. Stable IDs are what let
/// announcements fire once per object instead of once per frame.
///
/// Matching is greedy on IoU: the best-overlapping pairs are taken first, with ties broken
/// deterministically. Labels must agree, except that the generic geometric labels
/// ("obstacle", "wall", "pole", "low obstacle") are compatible with any other. Whether a geometric obstacle gets a model label
/// depends on the model seeing it that frame, and a missed frame must not turn a chair into
/// a new object. A track keeps the most specific label it has seen.
///
/// Feed frames in timestamp order.
struct ObjectTracker: Sendable {
    /// Boxes must overlap at least this much (IoU) to be the same object.
    var minimumIoU: CGFloat = 0.3
    /// A track not seen for this long, in seconds, is dropped. Covers a few missed frames at
    /// the analysis rate without keeping objects that have left the view.
    var maximumAge: TimeInterval = 0.6

    private struct Track {
        var label: String
        var boundingBox: CGRect
        var lastSeen: TimeInterval
    }

    private var tracks: [UUID: Track] = [:]

    init() {}

    /// IDs of the objects currently being tracked, including ones briefly out of view.
    var activeTrackIDs: Set<UUID> { Set(tracks.keys) }

    /// Matches one frame's detections against the active tracks.
    ///
    /// - Parameter timestamp: The frame's capture time in seconds, e.g. `ARFrame.timestamp`.
    /// - Returns: `detections` in the same order, each with `trackID` set and, for a generic
    ///   obstacle on a labelled track, the track's label.
    mutating func update(_ detections: [Detection], at timestamp: TimeInterval) -> [Detection] {
        tracks = tracks.filter { timestamp - $0.value.lastSeen <= maximumAge }

        var candidates: [(iou: CGFloat, trackID: UUID, index: Int)] = []
        for (trackID, track) in tracks {
            for (index, detection) in detections.enumerated() where labelsMatch(track.label, detection.label) {
                let iou = track.boundingBox.intersectionOverUnion(with: detection.boundingBox)
                if iou > 0, iou >= minimumIoU {
                    candidates.append((iou, trackID, index))
                }
            }
        }
        candidates.sort {
            if $0.iou != $1.iou { return $0.iou > $1.iou }
            if $0.trackID != $1.trackID { return $0.trackID.uuidString < $1.trackID.uuidString }
            return $0.index < $1.index
        }

        var trackForDetection: [Int: UUID] = [:]
        var matchedTracks = Set<UUID>()
        for candidate in candidates
        where trackForDetection[candidate.index] == nil && !matchedTracks.contains(candidate.trackID) {
            trackForDetection[candidate.index] = candidate.trackID
            matchedTracks.insert(candidate.trackID)
        }

        return detections.enumerated().map { index, detection in
            let id = trackForDetection[index] ?? UUID()
            var tracked = detection
            // A track keeps the most specific label it has seen: a chair the model missed
            // this frame is still a chair, not a fresh "obstacle". Between two generic
            // labels the newer shape reading wins.
            var label = detection.label
            if detection.hasGenericLabel, let previous = tracks[id]?.label, !Detection.genericLabels.contains(previous) {
                label = previous
            }
            tracked.trackID = id
            tracked.label = label
            tracks[id] = Track(label: label, boundingBox: detection.boundingBox, lastSeen: timestamp)
            return tracked
        }
    }

    private func labelsMatch(_ a: String, _ b: String) -> Bool {
        a == b || Detection.genericLabels.contains(a) || Detection.genericLabels.contains(b)
    }
}

extension Detection {
    /// The label of a geometric obstacle no model has recognized and whose shape says
    /// nothing more specific.
    static let obstacleLabel = "obstacle"

    /// Every label geometry alone can give (`GeometricObstacle.Kind`). Compatible with any
    /// specific label when tracking, since the same object may be recognized one frame and
    /// not the next.
    static let genericLabels: Set<String> = Set(GeometricObstacle.Kind.allCases.map(\.label))

    var hasGenericLabel: Bool { Self.genericLabels.contains(label) }
}
