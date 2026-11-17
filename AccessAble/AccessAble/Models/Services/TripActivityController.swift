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
            for await event in events {
                switch event {
                case .route(let latest):
                    route = latest
                case .state(let state):
                    if let action = planner.action(for: state, route: route, formatter: distances.formatter) {
                        await perform(action)
                    }
                }
            }
            if let action = planner.finish() { await perform(action) }
            group.cancelAll()
        }
    }

    private func perform(_ action: TripActivityPlanner.Action) async {
        switch action {
        case .start(let destinationName, let state):
            do {
                try await activity.start(TripActivityAttributes(destinationName: destinationName), state: state)
            } catch {
                log.error("No Live Activity for this trip: \(error.localizedDescription, privacy: .public)")
            }
        case .update(let state):
            await activity.update(state)
        case .end(let state, let immediately):
            await activity.end(state, immediately: immediately)
        }
    }
}
