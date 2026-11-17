import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "LiveActivity")

/// Keeps the trip's Live Activity in step with the trip, so the next turn can be read on the lock
/// screen. Outside `TripManager`, which stays free of ActivityKit; a trip never fails because of
/// its activity. Runs until its task is cancelled or the trip stream ends.
struct TripActivityController: Sendable {
    let trip: any TripStateProviding
    let activity: any TripActivityClient
    let distances: DistanceSettings

    private enum Event {
        case state(TripState)
        case route(NavigationRoute?)
    }

    func run() async {
        // nothing is shown yet, so anything on the lock screen is from a launch that ended mid-trip
        await activity.endAll()
        let (events, continuation) = AsyncStream<Event>.makeStream()
        await withDiscardingTaskGroup { group in
            group.addTask {
                for await route in trip.tripRoutes() { continuation.yield(.route(route)) }
            }
            group.addTask {
                for await state in trip.tripStates() { continuation.yield(.state(state)) }
                continuation.finish()
            }
            var planner = TripActivityPlanner()
            var route: NavigationRoute?
            var state: TripState?
            for await event in events {
                switch event {
                case .route(let latest):
                    // a state can arrive before its route, and a reroute changes the arrival time
                    route = latest
                case .state(let latest):
                    state = latest
                }
                guard let state,
                      let action = planner.action(for: state, route: route, formatter: distances.formatter)
                else { continue }
                if !(await perform(action)) { planner.startFailed() }
            }
            if let action = planner.finish() { await perform(action) }
            group.cancelAll()
        }
    }

    /// False when the activity couldn't start.
    @discardableResult
    private func perform(_ action: TripActivityPlanner.Action) async -> Bool {
        switch action {
        case .start(let destinationName, let state, let staleDate):
            do {
                try await activity.start(TripActivityAttributes(destinationName: destinationName), state: state,
                                         staleDate: staleDate)
            } catch TripActivityStartError.activitiesDisabled {
                log.info("No Live Activity for this trip: the user has turned them off")
                return false
            } catch {
                log.error("No Live Activity for this trip: \(error.localizedDescription, privacy: .public)")
                return false
            }
        case .update(let state, let staleDate):
            await activity.update(state, staleDate: staleDate)
        case .end(let state, let immediately):
            await activity.end(state, immediately: immediately)
        }
        return true
    }
}
