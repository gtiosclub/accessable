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
    func startTrip(route: NavigationRoute, destination: Destination, preferences: RoutePreferences,
                   resumingAtStep: Int?) async {}
    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {}
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
    func startTrip(route: NavigationRoute, destination: Destination, preferences: RoutePreferences,
                   resumingAtStep: Int?) async {}
    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {}
}

private actor RecordingActivity: TripActivityClient {
    struct Refused: Error {}

    private(set) var calls: [String] = []
    /// What each start and update was given, in order.
    private(set) var staleDates: [Date?] = []
    private var failingStarts: Int
    private let failure: any Error
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(failingStarts: Int = 0, failure: any Error = Refused()) {
        self.failingStarts = failingStarts
        self.failure = failure
    }

    func start(
        _ attributes: TripActivityAttributes, state: TripActivityAttributes.ContentState, staleDate: Date?
    ) async throws {
        staleDates.append(staleDate)
        record("start \(attributes.destinationName): \(state.instruction), \(state.distance ?? "-")")
        guard failingStarts == 0 else {
            failingStarts -= 1
            throw failure
        }
    }

    func update(_ state: TripActivityAttributes.ContentState, staleDate: Date?) async {
        staleDates.append(staleDate)
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
                  distance: Double? = 45.72, at time: Date = .now) -> TripState {
    TripState(phase: phase, destinationName: "Clough Commons",
              nextManeuver: Maneuver(kind: .turnLeft, instruction: instruction,
                                     coordinate: GeoCoordinate(latitude: 33.775, longitude: -84.399)),
              distanceToNextManeuver: distance, distanceRemaining: 280, updatedAt: time)
}

struct TripActivityControllerTests {
    private func calls(
        for states: [TripState], activity: RecordingActivity = RecordingActivity(), units: DistanceUnits = .feet
    ) async -> [String] {
        await TripActivityController(trip: ScriptedTrip(states: states), activity: activity,
                                     distances: DistanceSettings(units: units),
                                     foregrounds: AsyncStream { $0.finish() }).run()
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
            "update paused: Turn left onto Ferst Drive, -",
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
    func theStaleDateIsPassedThrough() async {
        let time = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let activity = RecordingActivity()
        _ = await calls(for: [trip(.active, at: time), trip(.active, distance: 30, at: time + 5)], activity: activity)
        #expect(await activity.staleDates == [time + TripActivityPlanner.staleAfter,
                                              time + 5 + TripActivityPlanner.staleAfter])
    }

    @Test(.timeLimit(.minutes(1)))
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
            trip: provider, activity: activity, distances: DistanceSettings(units: .feet),
            foregrounds: AsyncStream { $0.finish() }
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

    @Test(.timeLimit(.minutes(1)))
    func aFailedStartIsTriedAgainWhenTheAppComesToTheForeground() async {
        let provider = ControlledTrip()
        // what the real client throws when asked in the background
        let activity = RecordingActivity(failingStarts: 1, failure: TripActivityStartError.notInForeground)
        let (foregrounds, foreground) = AsyncStream<Void>.makeStream()
        let controller = TripActivityController(
            trip: provider, activity: activity, distances: DistanceSettings(units: .feet), foregrounds: foregrounds
        )
        let running = Task { await controller.run() }

        provider.states.yield(trip(.active))
        await activity.waitForCalls(2)
        foreground.yield()
        await activity.waitForCalls(3)
        provider.states.finish()
        await running.value

        #expect(await activity.calls == [
            "end all",
            "start Clough Commons: Turn left onto Ferst Drive, 150 ft",
            "start Clough Commons: Turn left onto Ferst Drive, 150 ft",
            "end active now",
        ])
    }
}
