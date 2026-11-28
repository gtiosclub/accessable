import Foundation
import Synchronization
@testable import AccessAble

/// Candidates whose names contain the query, ignoring case.
private func filtered(_ candidates: [DestinationCandidate], by query: String) -> [DestinationCandidate] {
    candidates.filter { $0.names.contains { $0.localizedStandardContains(query) } }
}

struct FixedNicknames: NicknameDestinationSource {
    var candidates: [DestinationCandidate] = []
    func destinations(matching query: String) -> [DestinationCandidate] { filtered(candidates, by: query) }
}

struct FixedSaved: SavedDestinationSource {
    var candidates: [DestinationCandidate] = []
    func destinations(matching query: String) async -> [DestinationCandidate] { filtered(candidates, by: query) }
}

/// MapKit results the test sets, or an error to throw; records the regions it searched in.
final class FixedMapKit: MapDestinationSource {
    private let candidates: [DestinationCandidate]
    private let error: (any Error & Sendable)?
    private let searchedRegions = Mutex<[SearchRegion]>([])

    init(_ candidates: [DestinationCandidate] = [], error: (any Error & Sendable)? = nil) {
        self.candidates = candidates
        self.error = error
    }

    var searches: Int { regions.count }
    var regions: [SearchRegion] { searchedRegions.withLock { $0 } }

    func destinations(matching query: String, in region: SearchRegion) async throws -> [DestinationCandidate] {
        searchedRegions.withLock { $0.append(region) }
        if let error { throw error }
        return filtered(candidates, by: query)
    }
}

/// A MapKit search that waits, ignoring cancellation, until the test releases it with a result.
final class GatedMapKit: MapDestinationSource {
    private let pending = Mutex<CheckedContinuation<[DestinationCandidate], Never>?>(nil)
    private let started = AsyncStream.makeStream(of: Void.self)

    func destinations(matching query: String, in region: SearchRegion) async throws -> [DestinationCandidate] {
        await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
            started.continuation.yield()
        }
    }

    /// Returns once a search is waiting.
    func waitUntilStarted() async {
        for await _ in started.stream { return }
    }

    func release(_ candidates: [DestinationCandidate]) {
        pending.withLock { $0.take() }?.resume(returning: candidates)
    }
}

extension DestinationLookup {
    static func fixed(
        nicknames: [DestinationCandidate] = [],
        saved: [DestinationCandidate] = [],
        mapKit: any MapDestinationSource = FixedMapKit()
    ) -> DestinationLookup {
        DestinationLookup(nicknames: FixedNicknames(candidates: nicknames), saved: FixedSaved(candidates: saved),
                          mapKit: mapKit)
    }
}

extension Destination {
    static func at(_ name: String, _ latitude: Double = 33.77, _ longitude: Double = -84.40) -> Destination {
        Destination(name: name, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude))
    }
}
