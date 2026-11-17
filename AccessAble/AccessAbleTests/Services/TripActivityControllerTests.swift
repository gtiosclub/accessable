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

/// States and routes the test sends one at a time; the states stream finishes when the test says.
private final class ControlledTrip: TripStateProviding {
    let states: AsyncStream<TripState>.Continuation
    let routes: AsyncStream<NavigationRoute?>.Continuation
    private let stateStream: AsyncStream<TripState>
    private let routeStream: AsyncStream<NavigationRoute?>

    init() {
        (stateStream, states) = AsyncStream.makeStream()
        (routeStream, routes) = AsyncStream.makeStream()
    }

    func tripStates() -> AsyncStream<TripState> { stateStream }
    func tripRoutes() -> AsyncStream<NavigationRoute?> { routeStream }
    func startTrip(route: NavigationRoute, destination: Destination) async {}
    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
}

private actor RecordingActivity: TripActivityClient {
    struct Refused: Error {}

    private(set) var calls: [String] = []
    private var failingStarts: Int
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(failingStarts: Int = 0) { self.failingStarts = failingStarts }

    func start(_ attributes: TripActivityAttributes, state: TripActivityAttributes.ContentState) async throws {
        record("start \(attributes.destinationName): \(state.instruction), \(state.distance ?? "-")")
        guard failingStarts == 0 else {
            failingStarts -= 1
            throw Refused()
        }
    }

    func update(_ state: TripActivityAttributes.ContentState) async {
        record("update \(state.status): \(state.instruction), \(state.distance ?? "-")"
            + (state.arrival == nil ? "" : ", arrives"))
    }

    func end(_ state: TripActivityAttributes.ContentState, immediately: Bool) async {
        record("end \(state.status)\(immediately ? " now" : "")")
    }

    func endAll() async { record("end all") }

    func waitForCalls(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    private func record(_ call: String) {
        calls.append(call)
        let ready = waiters.filter { $0.count <= calls.count }
        waiters.removeAll { $0.count <= calls.count }
        ready.forEach { $0.continuation.resume() }
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
            "end all",
            "start Clough Commons: Turn left onto Ferst Drive, 150 ft",
            "update active: Turn left onto Ferst Drive, 100 ft",
            "update paused: Turn left onto Ferst Drive, 100 ft",
            "update active: Arrive, 75 ft",
            "end arrived",
            "end arrived now",
        ])
    }

    @Test
    func clearsActivitiesLeftByAnEarlierLaunch() async {
        #expect(await calls(for: []) == ["end all"])
    }

    @Test
    func endingTheTripRemovesItNow() async {
        #expect(await calls(for: [trip(.active), .idle]) == [
            "end all",
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
        #expect(await calls(for: [trip(.active)], units: .metres).dropFirst().first
            == "start Clough Commons: Turn left onto Ferst Drive, 50 m")
    }

    @Test
    func aFailedStartIsTriedAgainAtTheNextStep() async {
        let calls = await calls(for: [trip(.active), trip(.active, distance: 20), trip(.active, "Arrive"), .idle],
                                activity: RecordingActivity(failingStarts: 1))
        #expect(calls == [
            "end all",
            "start Clough Commons: Turn left onto Ferst Drive, 150 ft",
            "start Clough Commons: Arrive, 150 ft",
            "end active now",
        ])
    }

    @Test
    func aRouteAfterItsStateAddsTheArrivalTime() async throws {
        let origin = GeoCoordinate(latitude: 33.775, longitude: -84.399)
        let route = try NavigationRoute(
            coordinates: [origin, TripWalk.destination(from: origin, bearing: 0, distance: 280)],
            steps: [
                RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Head north.",
                          spokenInstruction: "Head north."),
                RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "Arrive."),
            ],
            estimatedDuration: 200
        )
        let provider = ControlledTrip()
        let activity = RecordingActivity()
        let controller = TripActivityController(
            trip: provider, activity: activity, distances: DistanceSettings(units: .feet)
        )
        let running = Task { await controller.run() }

        provider.states.yield(trip(.active))
        await activity.waitForCalls(2)
        provider.routes.yield(route)
        await activity.waitForCalls(3)
        provider.states.finish()
        await running.value

        #expect(await activity.calls == [
            "end all",
            "start Clough Commons: Turn left onto Ferst Drive, 150 ft",
            "update active: Turn left onto Ferst Drive, 150 ft, arrives",
            "end active now",
        ])
    }
}
