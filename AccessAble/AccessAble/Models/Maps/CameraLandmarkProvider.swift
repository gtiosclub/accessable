import Foundation
import Synchronization

/// Turns signs the camera reads during a trip into landmark sightings for `TripManager` (the LAND-5 bridge).
///
/// Walk, the trip's camera mode, doesn't read text on its own, so text reading is switched on while anyone listens.
/// A building's name plate is no room sign, so `SignAnnouncer` never confirms it: plates are grouped and agreed here
/// instead, and `LandmarkMatcher` decides whether one names a building on the route.
final class CameraLandmarkProvider: LandmarkObserving {
    private let scene: any SceneObservationProviding
    private let setReadsText: @Sendable (Bool) -> Void
    private let isAnnouncedByCamera: @Sendable ([String]) -> Bool
    /// Trips overlap for a moment when one restarts, so reading stops only when the last listener goes.
    private let listeners = Mutex(0)

    /// - Parameters:
    ///   - setReadsText: switches the camera's text reading on or off.
    ///   - isAnnouncedByCamera: whether the camera speaks a plate of these lines itself.
    init(
        scene: any SceneObservationProviding,
        setReadsText: @escaping @Sendable (Bool) -> Void,
        isAnnouncedByCamera: @escaping @Sendable ([String]) -> Bool = { _ in false }
    ) {
        self.scene = scene
        self.setReadsText = setReadsText
        self.isAnnouncedByCamera = isAnnouncedByCamera
    }

    func landmarkObservations() -> AsyncStream<LandmarkObservation> {
        let (stream, continuation) = AsyncStream.makeStream(of: LandmarkObservation.self)
        let observations = scene.observations()
        if listeners.withLock({ $0 += 1; return $0 == 1 }) { setReadsText(true) }
        let task = Task { [isAnnouncedByCamera] in
            var signs = SignSightings()
            for await observation in observations {
                for sighting in signs.sightings(in: observation.recognizedText, at: observation.timestamp,
                                                isAnnounced: isAnnouncedByCamera) {
                    continuation.yield(sighting)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            guard let self else { return }
            if listeners.withLock({ $0 -= 1; return $0 == 0 }) { setReadsText(false) }
        }
        return stream
    }
}

/// Confirms a plate once two separate text reads agree on it, as `SignAnnouncer` does, so a half-read plate isn't
/// taken for a building.
struct SignSightings {
    var agreeingReads = 2
    /// A plate not seen for this long starts its count again.
    var forgetAfter: TimeInterval = 5
    /// The matcher takes each building once a trip, so a plate in view for long only needs sending now and then.
    var resendAfter: TimeInterval = 30

    /// Per plate, the reads that saw it (a read gives its lines new IDs, so the first line's ID stands for the read).
    private var reads: [String: (ids: Set<UUID>, lastSeen: Date)] = [:]
    private var lastSent: [String: Date] = [:]

    // words on doors and the signs beside them
    private static let entranceWords: Set<String> = ["entrance", "entry", "enter"]
    // "DO NOT ENTER" and "NO ENTRY" were read on the walk to West Village; they are no way in
    private static let negations: Set<String> = ["not", "no"]

    mutating func sightings(in texts: [RecognizedText], at time: Date,
                            isAnnounced: ([String]) -> Bool = { _ in false }) -> [LandmarkObservation] {
        reads = reads.filter { time.timeIntervalSince($0.value.lastSeen) <= forgetAfter }
        var sightings: [LandmarkObservation] = []
        for plate in SignAnnouncer.plates(texts) {
            let lines = plate.map(\.string)
            let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = LandmarkMatcher.tokens(text)
            guard text.filter(\.isLetter).count >= 3 else { continue }
            let key = tokens.joined(separator: " ")
            var entry = reads[key] ?? ([], time)
            entry.ids.insert(plate[0].id)
            entry.lastSeen = time
            reads[key] = entry
            guard entry.ids.count >= agreeingReads,
                  lastSent[key].map({ time.timeIntervalSince($0) >= resendAfter }) ?? true
            else { continue }
            lastSent[key] = time
            sightings.append(LandmarkObservation(
                kind: tokens.contains(where: Self.entranceWords.contains) && !tokens.contains(where: Self.negations.contains)
                    ? .entrance : .signText,
                text: text,
                key: "sign-\(key)",
                confidence: plate.map(\.confidence).reduce(0, +) / Float(plate.count),
                wasAnnounced: isAnnounced(lines),
                timestamp: time
            ))
        }
        return sightings
    }
}
