import Foundation

/// What the trip's Live Activity should do for each trip state: start when guidance begins, update
/// at each new step and every 25 ft or so, end at arrival or when the trip ends. Pure, so
/// `TripActivityController` stays a thin loop and the throttling is tested without ActivityKit.
struct TripActivityPlanner {
    typealias Content = TripActivityAttributes.ContentState

    enum Action: Equatable {
        case start(destinationName: String, Content)
        case update(Content)
        case end(Content, immediately: Bool)
    }

    /// 25 ft, the step the written distance rounds to: the lock screen stays true to the nearest
    /// step without spending ActivityKit's update budget, and the battery, on every GPS fix.
    static let minimumDistanceChange = 7.62

    private struct Shown {
        var content: Content
        var maneuver: Maneuver
        var distance: Double?
    }

    /// What the running activity shows; nil when none is running.
    private var shown: Shown?

    mutating func action(for state: TripState, route: NavigationRoute?, formatter: DistanceFormatter) -> Action? {
        switch state.phase {
        case .planning:
            return finish()
        case .arrived:
            guard shown != nil else { return nil }
            shown = nil
            return .end(Self.arrived, immediately: false)
        case .active, .paused:
            guard let maneuver = state.nextManeuver, let destinationName = state.destinationName else { return nil }
            let content = Self.content(for: state, maneuver: maneuver, route: route, formatter: formatter)
            let next = Shown(content: content, maneuver: maneuver, distance: state.distanceToNextManeuver)
            guard let shown else {
                self.shown = next
                return .start(destinationName: destinationName, content)
            }
            guard Self.differs(next, from: shown) else { return nil }
            self.shown = next
            return .update(content)
        }
    }

    /// The trip ended, or its stream did, with the activity still showing: take it off the lock screen.
    mutating func finish() -> Action? {
        guard let shown else { return nil }
        self.shown = nil
        return .end(shown.content, immediately: true)
    }

    private static func differs(_ next: Shown, from shown: Shown) -> Bool {
        guard next.content.status == shown.content.status, next.maneuver == shown.maneuver else { return true }
        switch (next.distance, shown.distance) {
        case let (next?, shown?): return abs(next - shown) >= minimumDistanceChange
        case (nil, nil): return false
        default: return true
        }
    }

    private static func content(
        for state: TripState, maneuver: Maneuver, route: NavigationRoute?, formatter: DistanceFormatter
    ) -> Content {
        let status: Content.Status = state.phase == .paused ? .paused : state.isOffRoute ? .offRoute : .active
        return Content(
            status: status,
            instruction: maneuver.instruction,
            distance: status == .offRoute ? nil : state.distanceToNextManeuver.map(formatter.written),
            symbolName: maneuver.kind.symbolName,
            arrival: status == .active ? arrival(for: state, route: route) : nil
        )
    }

    /// At the walking speed the route's estimated duration assumes.
    private static func arrival(for state: TripState, route: NavigationRoute?) -> Date? {
        guard let route, route.estimatedDuration > 0, route.totalDistance > 0,
              let remaining = state.distanceRemaining
        else { return nil }
        return state.updatedAt.addingTimeInterval(remaining * route.estimatedDuration / route.totalDistance)
    }

    private static let arrived = Content(
        status: .arrived, instruction: "You have arrived", distance: nil,
        symbolName: ManeuverKind.arrive.symbolName, arrival: nil
    )
}
