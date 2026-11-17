import Foundation

/// What the trip's Live Activity should do for each trip state: start when guidance begins, update
/// at each new step and roughly every 25 ft, end at arrival or when the trip ends. Pure, so
/// `TripActivityController` stays a thin loop and the throttling is tested without ActivityKit.
struct TripActivityPlanner {
    typealias Content = TripActivityAttributes.ContentState

    enum Action: Equatable {
        case start(destinationName: String, Content)
        case update(Content)
        case end(Content, immediately: Bool)
    }

    /// 25 ft. A new distance is pushed only once the written one changes, and only this far from the last
    /// push, so GPS jitter at a rounding boundary can't flip the lock screen back and forth. Feet round to
    /// 25 ft and metres to 10 m, so short distances still change about this often; miles change every 0.1 mi.
    static let minimumDistanceChange = 25 * 0.3048
    /// The arrival time is pushed when it moves by at least this, since the lock screen shows it to the minute.
    static let minimumArrivalChange: TimeInterval = 60

    private struct Shown {
        var content: Content
        var maneuver: Maneuver
        var distance: Double?
    }

    /// What the running activity shows; nil when none is running.
    private var shown: Shown?
    /// The arrived card is still on the lock screen, for ending the trip to clear.
    private var showsArrival = false
    /// What a failed start would have shown. Tried again only at a new step or status, not on every fix,
    /// since the cause (Live Activities turned off) rarely clears within a step.
    private var failedStart: Shown?

    mutating func action(for state: TripState, route: NavigationRoute?, formatter: DistanceFormatter) -> Action? {
        switch state.phase {
        case .planning:
            failedStart = nil
            return finish()
        case .arrived:
            failedStart = nil
            guard shown != nil else { return nil }
            shown = nil
            showsArrival = true
            return .end(Self.arrived, immediately: false)
        case .active, .paused:
            guard let maneuver = state.nextManeuver, let destinationName = state.destinationName else { return nil }
            let content = Self.content(for: state, maneuver: maneuver, route: route, formatter: formatter)
            let next = Shown(content: content, maneuver: maneuver, distance: state.distanceToNextManeuver)
            guard let shown else {
                if let failedStart, next.content.status == failedStart.content.status,
                   next.maneuver == failedStart.maneuver {
                    return nil
                }
                failedStart = nil
                self.shown = next
                showsArrival = false
                return .start(destinationName: destinationName, content)
            }
            guard Self.differs(next, from: shown) else { return nil }
            self.shown = next
            return .update(content)
        }
    }

    /// The client couldn't start the activity: the next step or status tries again.
    mutating func startFailed() {
        failedStart = shown
        shown = nil
    }

    /// The trip ended, or its stream did: take the activity, or the arrived card, off the lock screen.
    mutating func finish() -> Action? {
        if let shown {
            self.shown = nil
            return .end(shown.content, immediately: true)
        }
        guard showsArrival else { return nil }
        showsArrival = false
        return .end(Self.arrived, immediately: true)
    }

    private static func differs(_ next: Shown, from shown: Shown) -> Bool {
        guard next.content.status == shown.content.status, next.maneuver == shown.maneuver else { return true }
        switch (next.content.arrival, shown.content.arrival) {
        case let (next?, shown?) where abs(next.timeIntervalSince(shown)) >= minimumArrivalChange: return true
        case (_?, nil), (nil, _?): return true
        default: break
        }
        switch (next.distance, shown.distance) {
        case let (nextDistance?, shownDistance?):
            return next.content.distance != shown.content.distance
                && abs(nextDistance - shownDistance) >= minimumDistanceChange
        case (nil, nil): return false
        default: return true
        }
    }

    private static func content(
        for state: TripState, maneuver: Maneuver, route: NavigationRoute?, formatter: DistanceFormatter
    ) -> Content {
        let status: Content.Status = state.phase == .paused ? .paused : state.isOffRoute ? .offRoute : .active
        let distance = status == .offRoute ? nil : state.distanceToNextManeuver
        return Content(
            status: status,
            instruction: maneuver.instruction,
            distance: distance.map(formatter.written),
            spokenDistance: distance.map(formatter.words),
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
        status: .arrived, instruction: "You have arrived", distance: nil, spokenDistance: nil,
        symbolName: ManeuverKind.arrive.symbolName, arrival: nil
    )
}
