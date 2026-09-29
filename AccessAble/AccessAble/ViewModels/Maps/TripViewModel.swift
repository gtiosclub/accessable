import Foundation
import Observation

/// Owner: Maps + Location (2.x). Active trip: next maneuver, pause/resume, end.
@MainActor
@Observable
final class TripViewModel {
    private(set) var tripState: TripState = .idle

    @ObservationIgnored private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var nextInstruction: String {
        guard let maneuver = tripState.nextManeuver else { return "No active trip" }
        guard let distance = tripState.distanceToNextManeuver else { return maneuver.instruction }
        return "In \(SpokenPhrasing.shortDistance(distance)), \(maneuver.instruction)"
    }

    func start() async {
        for await state in services.trip.tripStates() {
            tripState = state
        }
    }

    func togglePause() async {
        switch tripState.phase {
        case .active: await services.trip.pauseTrip()
        case .paused: await services.trip.resumeTrip()
        case .planning, .arrived: break
        }
    }

    func endTrip() async {
        await services.trip.endTrip()
    }
}
