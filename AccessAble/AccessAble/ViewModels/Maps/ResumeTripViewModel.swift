import Foundation
import Observation

/// Owner: Maps (2.x). At launch, offers to resume a trip the app was closed during.
@MainActor
@Observable
final class ResumeTripViewModel {
    /// The saved trip on offer, until the user answers.
    private(set) var offer: SavedTrip?

    @ObservationIgnored private let store: SavedTripStore?
    @ObservationIgnored private let trip: any TripStateProviding
    @ObservationIgnored private let now: () -> Date

    init(store: SavedTripStore?, trip: any TripStateProviding, now: @escaping () -> Date = { .now }) {
        self.store = store
        self.trip = trip
        self.now = now
    }

    var title: String {
        "Resume your trip to \(offer?.destination.name ?? "your destination")?"
    }

    /// Offers the saved trip, when there is one recent enough and no trip is running: one running, as when the main
    /// screens are rebuilt mid-trip, is the one saved.
    func check() async {
        guard let store else { return }
        var states = trip.tripStates().makeAsyncIterator()
        let phase = await states.next()?.phase
        guard phase == nil || phase == .planning else { return }
        offer = store.load()
    }

    /// The trip screen's plan for the saved trip. Its route counts as just found, so the start doesn't swap it for a
    /// new one; the trip places the user along it from the first fix, and reroutes if they are far off it.
    func resume() -> TripPlan? {
        guard let offer else { return nil }
        self.offer = nil
        return TripPlan(
            place: SamplePlace(destination: offer.destination), route: nil, isRecording: false,
            plannedRoute: PlannedRoute(destination: offer.destination, route: offer.route, requestedAt: now(),
                                       resumingAtStep: offer.passedStepCount)
        )
    }

    func decline() {
        offer = nil
        store?.clear()
    }
}
