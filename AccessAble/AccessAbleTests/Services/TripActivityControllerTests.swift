import Foundation
import Testing
@testable import AccessAble

/// Sends the given states, then finishes; no routes.
private struct ScriptedTrip: TripStateProviding {
    let states: [TripState]

    func tripStates() -> AsyncStream<TripState> {
        AsyncStream { continuation in
            states.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func tripRoutes() -> AsyncStream<NavigationRoute?> { AsyncStream { $0.finish() } }
    func startTrip(route: NavigationRoute, destination: Destination) async {}
    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
}

private actor RecordingActivity: TripActivityClient {
    struct Refused: Error {}

    private(set) var calls: [String] = []
    private let startFails: Bool

    init(startFails: Bool = false) { self.startFails = startFails }

    func start(_ attributes: TripActivityAttributes, state: TripActivityAttributes.ContentState) async throws {
        calls.append("start \(attributes.destinationName): \(state.instruction), \(state.distance ?? "-")")
        if startFails { throw Refused() }
    }

    func update(_ state: TripActivityAttributes.ContentState) async {
        calls.append("update \(state.status): \(state.instruction), \(state.distance ?? "-")")
    }

    func end(_ state: TripActivityAttributes.ContentState, immediately: Bool) async {
        calls.append("end \(state.status)\(immediately ? " now" : "")")
    }
}

private func trip(_ phase: TripPhase, _ instruction: String = "Turn left onto Ferst Drive",
                  distance: Double? = 45.72) -> TripState {
    TripState(phase: phase, destinationName: "Clough Commons",
              nextManeuver: Maneuver(kind: .turnLeft, instruction: instruction,
                                     coordinate: GeoCoordinate(latitude: 33.775, longitude: -84.399)),
              distanceToNextManeuver: distance, distanceRemaining: 280)
}

struct TripActivityControllerTests {
    private func calls(
        for states: [TripState], activity: RecordingActivity = RecordingActivity(), units: DistanceUnits = .feet
    ) async -> [String] {
        await TripActivityController(trip: ScriptedTrip(states: states), activity: activity,
                                     distances: DistanceSettings(units: units)).run()
        return await activity.calls
    }

    @Test
    func followsATripToArrival() async {
        let calls = await calls(for: [
            .idle,
            trip(.active),
            trip(.active, distance: 44),
            trip(.active, distance: 30),
            trip(.paused, distance: 30),
            trip(.active, "Arrive", distance: 20),
            trip(.arrived, "Arrive", distance: nil),
            .idle,
        ])
        #expect(calls == [
            "start Clough Commons: Turn left onto Ferst Drive, 150 ft",
            "update active: Turn left onto Ferst Drive, 100 ft",
            "update paused: Turn left onto Ferst Drive, 100 ft",
            "update active: Arrive, 75 ft",
            "end arrived",
        ])
    }

    @Test
    func endingTheTripRemovesItNow() async {
        #expect(await calls(for: [trip(.active), .idle]) == [
            "start Clough Commons: Turn left onto Ferst Drive, 150 ft",
            "end active now",
        ])
    }

    @Test
    func theStreamEndingMidTripRemovesItNow() async {
        #expect(await calls(for: [trip(.active)]).last == "end active now")
    }

    @Test
    func distanceFollowsTheUsersUnits() async {
        #expect(await calls(for: [trip(.active)], units: .metres).first
            == "start Clough Commons: Turn left onto Ferst Drive, 50 m")
    }

    @Test
    func aRefusedActivityDoesNotStopTheController() async {
        let calls = await calls(for: [trip(.active), trip(.paused), .idle],
                                activity: RecordingActivity(startFails: true))
        #expect(calls.count == 3)
        #expect(calls.last == "end paused now")
    }
}
