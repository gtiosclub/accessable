import CoreGraphics
import Foundation

/// Maintains stable object identities across consecutive detection frames.
///
/// Matching is deliberately simple for the first implementation: detections must share a
/// label and meet the IoU threshold, then the highest-IoU pairs win greedily. Feed every
/// analyzed frame to `track(_:at:)`; the returned objects correspond to detections visible
/// in that frame, while briefly missing objects remain in `activeTracks` for recovery.
struct ObjectTracker: Sendable {
    /// Tracks retained between calls, keyed by their persistent identities.
    private(set) var activeTracks: [UUID: TrackedObject] = [:]

    let minimumIoU: CGFloat
    let maximumMissedFrames: Int

    private var missedFrames: [UUID: Int] = [:]
    private var latestProcessedTimestamp: Date?

    init(minimumIoU: CGFloat = 0.3, maximumMissedFrames: Int = 5) {
        self.minimumIoU = min(max(minimumIoU, 0), 1)
        self.maximumMissedFrames = max(maximumMissedFrames, 0)
    }

    /// Matches one frame of detections against active tracks and returns its tracked objects.
    ///
    /// Unmatched tracks are retained until they have missed more than `maximumMissedFrames`
    /// consecutive input frames. A frame with a non-increasing timestamp is discarded
    /// entirely, so it cannot regress tracks, create stale tracks, or age other tracks.
    mutating func track(_ detections: [Detection], at timestamp: Date) -> [TrackedObject] {
        if let latestProcessedTimestamp, timestamp <= latestProcessedTimestamp {
            return []
        }
        latestProcessedTimestamp = timestamp

        struct Candidate {
            let trackID: UUID
            let detectionIndex: Int
            let iou: CGFloat
        }

        var candidates: [Candidate] = []
        for (trackID, trackedObject) in activeTracks {
            for (detectionIndex, detection) in detections.enumerated()
            where trackedObject.label == detection.label {
                let iou = intersectionOverUnion(trackedObject.boundingBox, detection.boundingBox)
                // A zero threshold means any actual overlap is acceptable, not that two
                // disjoint objects of the same class may inherit one another's identity.
                if iou > 0, iou >= minimumIoU {
                    candidates.append(Candidate(
                        trackID: trackID,
                        detectionIndex: detectionIndex,
                        iou: iou
                    ))
                }
            }
        }

        candidates.sort {
            if $0.iou != $1.iou { return $0.iou > $1.iou }
            if $0.trackID != $1.trackID { return $0.trackID.uuidString < $1.trackID.uuidString }
            return $0.detectionIndex < $1.detectionIndex
        }

        var matchedTrackIDs = Set<UUID>()
        var matchedDetectionIndices = Set<Int>()
        var trackForDetection: [Int: UUID] = [:]

        for candidate in candidates
        where !matchedTrackIDs.contains(candidate.trackID)
            && !matchedDetectionIndices.contains(candidate.detectionIndex) {
            matchedTrackIDs.insert(candidate.trackID)
            matchedDetectionIndices.insert(candidate.detectionIndex)
            trackForDetection[candidate.detectionIndex] = candidate.trackID
        }

        for trackID in activeTracks.keys where !matchedTrackIDs.contains(trackID) {
            let misses = missedFrames[trackID, default: 0] + 1
            if misses > maximumMissedFrames {
                activeTracks.removeValue(forKey: trackID)
                missedFrames.removeValue(forKey: trackID)
            } else {
                missedFrames[trackID] = misses
            }
        }

        var trackedDetections: [TrackedObject] = []
        for (detectionIndex, detection) in detections.enumerated() {
            if let trackID = trackForDetection[detectionIndex], let previous = activeTracks[trackID] {
                let elapsed = timestamp.timeIntervalSince(previous.lastSeen)
                let previousCenter = CGPoint(x: previous.boundingBox.midX, y: previous.boundingBox.midY)
                let newCenter = CGPoint(x: detection.boundingBox.midX, y: detection.boundingBox.midY)
                let velocity = CGVector(
                    dx: (newCenter.x - previousCenter.x) / elapsed,
                    dy: (newCenter.y - previousCenter.y) / elapsed
                )

                let updated = TrackedObject(
                    id: trackID,
                    label: detection.label,
                    boundingBox: detection.boundingBox,
                    confidence: detection.confidence,
                    imageVelocity: velocity,
                    lastSeen: timestamp
                )
                activeTracks[trackID] = updated
                missedFrames[trackID] = 0
                trackedDetections.append(updated)
            } else {
                let newTrack = TrackedObject(
                    label: detection.label,
                    boundingBox: detection.boundingBox,
                    confidence: detection.confidence,
                    lastSeen: timestamp
                )
                activeTracks[newTrack.id] = newTrack
                missedFrames[newTrack.id] = 0
                trackedDetections.append(newTrack)
            }
        }

        return trackedDetections
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }

        let union = lhs.width * lhs.height + rhs.width * rhs.height
            - intersection.width * intersection.height
        return union > 0 ? intersection.width * intersection.height / union : 0
    }
}
