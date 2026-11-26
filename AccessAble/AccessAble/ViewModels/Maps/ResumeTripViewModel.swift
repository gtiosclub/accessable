import Foundation
import Observation

/// Owner: Maps (2.x). At launch, offers to resume a trip the app was closed during.
@MainActor
@Observable
final class ResumeTripViewModel {
    /// The saved trip on offer, until the user answers or the prompt goes away.
    private(set) var offer: SavedTrip?
    /// The prompt's, kept once the offer goes, so it doesn't change as the prompt closes.
    private(set) var title = ""

    @ObservationIgnored private let store: SavedTripStore?
    @ObservationIgnored private let trip: any TripStateProviding
    @ObservationIgnored private let now: () -> Date

    init(store: SavedTripStore?, trip: any TripStateProviding, now: @escaping () -> Date = { .now }) {
        self.store = store
        self.trip = trip
        self.now = now
    }

    /// Offers the saved trip, when there is one recent enough and no trip is running: one running, as when the main
    /// screens are rebuilt mid-trip, is the one saved.
    func check() async {
        guard let store else { return }
        var states = trip.tripStates().makeAsyncIterator()
        let phase = await states.next()?.phase
        guard phase == nil || phase == .planning, let saved = store.load() else { return }
        offer = saved
        title = "Resume your trip to \(saved.destination.name)?"
    }

    /// The trip screen's plan for `offer` as the prompt showed it: the prompt may have gone away, and taken the offer,
    /// before its button's action runs. Its route counts as just found, so the start doesn't swap it for a new one; the
    /// trip places the user along it from the first fix, and reroutes if they are far off it.
    func resume(_ offer: SavedTrip) -> TripPlan {
        self.offer = nil
        var route = offer.route
        route.source = offer.routeSource
        return TripPlan(
            place: SamplePlace(destination: offer.destination), route: nil, isRecording: false,
            plannedRoute: PlannedRoute(destination: offer.destination, route: route, requestedAt: now(),
                                       resumingAtStep: offer.passedStepCount)
        )
    }

    /// The prompt went away without an answer. The trip stays saved, to offer at the next launch.
    func dismiss() {
        offer = nil
    }

    func decline() {
        offer = nil
        store?.clear()
    }
}
