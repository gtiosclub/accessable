import Foundation
import Observation

/// Owner: Maps + Location (2.x). Active trip: next maneuver, pause/resume, end.
@MainActor
@Observable
final class TripViewModel {
    private(set) var tripState: TripState = .idle
    private(set) var destination: Destination?
    private(set) var locationAuthorization: LocationAuthorization = .notDetermined

    @ObservationIgnored private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func setDestination(_ destination: Destination) {
        self.destination = destination
    }

    var nextInstruction: String {
        guard let maneuver = tripState.nextManeuver else { return "No active trip" }
        guard let distance = tripState.distanceToNextManeuver else { return maneuver.instruction }
        return "In \(SpokenPhrasing.shortDistance(distance)), \(maneuver.instruction)"
    }
    
    var needsLocationAccess: Bool {
        switch locationAuthorization {
        case .notDetermined:
            false
        case .restricted:
            true
        case .denied:
            true
        case .authorized:
            false
        }
    }

    func start() async {
        await services.location.requestAuthorization()
        
        await withDiscardingTaskGroup { group in
            group.addTask { [services] in
                for await state in services.trip.tripStates() {
                    await self.receive(state)
                }
            }
            group.addTask { [services] in
                for await authorization in services.location.authorizationStates() {
                    await self.receive(authorization)
                }
            }
            
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
    
    private func receive(_ state: TripState) {tripState = state}
    private func receive(_ authorization: LocationAuthorization) { locationAuthorization = authorization}
}
