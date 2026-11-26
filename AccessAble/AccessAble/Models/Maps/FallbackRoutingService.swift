import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "AccessAble", category: "Routing")

/// Asks each of `primaries` (Valhalla servers) in order and, when they all fail or take longer than `timeout`,
/// `fallback` (Apple Maps). The servers share `chainBudget`: each waits at most what is left of it, and once it is
/// spent no later server is asked, so two hanging servers cost one wait of `chainBudget` before Apple Maps, not two
/// of `timeout`. Apple Maps' routes come back with `source` `.appleMaps` for the caller to tell the user. Moving
/// from one Valhalla server to the next is silent, since their routes are alike. Cancellation is passed on, never
/// treated as a failure, and no later server is asked.
///
/// Apple Maps can't avoid places, so a request that excludes some never falls back to it: when every Valhalla server
/// fails or times out it throws `.noRouteFound` if one found no route, else `.exclusionsRejected`, for
/// `ReportAwareRoutingService` to try again with fewer exclusions. Its last try has none, so a route it gets from
/// Apple Maps still lists the reports it passes.
///
/// After a timeout (including one cut short by `chainBudget`), a rejected key or an exhausted usage limit, that
/// server is skipped for `timeoutMemory`, so a dead or refusing server doesn't cost the wait or the request again at
/// each of those tries and each reroute: requests go to the next server, or once none is left, are rejected at once
/// with exclusions and go to Apple Maps without.
struct FallbackRoutingService: RoutingService {
    static let defaultTimeout: Duration = .seconds(6)
    /// How long all the Valhalla servers of one request may take together before Apple Maps is asked.
    static let chainBudget: Duration = .seconds(8)
    /// After a timeout or a refusal, how long requests skip that server, so each try and each reroute doesn't repeat it.
    static let timeoutMemory: Duration = .seconds(120)

    /// The Valhalla servers, in the order they are asked.
    let primaries: [any RoutingService]
    private let fallback: any RoutingService
    private let timeout: Duration
    private let clock: any Clock<Duration>
    /// Each primary's last timeout or refusal, cleared when it answers. Shared by copies.
    private let lastTimeouts: [TimeoutMemory]
    /// How the logs name each primary: its host, so field logs say which server failed without a key or a query.
    private let serverNames: [String]

    init(
        primaries: [any RoutingService],
        fallback: any RoutingService,
        timeout: Duration = FallbackRoutingService.defaultTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.primaries = primaries
        self.fallback = fallback
        self.timeout = timeout
        self.clock = clock
        lastTimeouts = primaries.map { _ in TimeoutMemory() }
        serverNames = primaries.enumerated().map { index, primary in
            (primary as? ValhallaRoutingService)?.endpoint.baseURL.host() ?? "\(index + 1)"
        }
    }

    init(
        primary: any RoutingService,
        fallback: any RoutingService,
        timeout: Duration = FallbackRoutingService.defaultTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.init(primaries: [primary], fallback: fallback, timeout: timeout, clock: clock)
    }

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        let excludes = !options.excludeLocations.isEmpty || !options.excludePolygons.isEmpty
        var primaryErrors: [RoutingError] = []
        let elapsed = clock.stopwatch()
        for (index, primary) in primaries.enumerated() {
            try Task.checkCancellation()
            let server = serverNames[index]
            let lastTimeout = lastTimeouts[index]
            if let outage = lastTimeout.outage, outage.elapsed < Self.timeoutMemory {
                let what = outage.refusal.map { String(describing: $0) } ?? "timed out"
                log.notice("Valhalla server \(server, privacy: .public) \(what, privacy: .public) \(String(describing: outage.elapsed), privacy: .public) ago, skipping it")
                if let refusal = outage.refusal { primaryErrors.append(refusal) }
                continue
            }
            let wait = min(timeout, Self.chainBudget - elapsed())
            guard wait > .zero else {
                log.notice("Valhalla servers used their \(String(describing: Self.chainBudget), privacy: .public), skipping \(server, privacy: .public)")
                continue
            }
            do {
                let route = try await primaryRoute(primary, timeout: wait, from: origin, to: destination,
                                                   options: options)
                lastTimeout.clear()
                return route
            } catch is CancellationError where Task.isCancelled {
                throw CancellationError()
            } catch is PrimaryTimedOut {
                log.error("Valhalla server \(server, privacy: .public) took longer than \(String(describing: wait), privacy: .public)")
                lastTimeout.record(clock.stopwatch(), refusal: nil)
            } catch {
                log.error("Valhalla server \(server, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                let routingError = error as? RoutingError ?? .invalidResponse
                if routingError == .notAuthorized || routingError == .usageLimitReached {
                    lastTimeout.record(clock.stopwatch(), refusal: routingError)
                }
                primaryErrors.append(routingError)
            }
        }
        if excludes {
            // no route at all is the answer; anything else may be the exclusions' fault, so fewer can be tried
            throw primaryErrors.contains(.noRouteFound) ? RoutingError.noRouteFound : RoutingError.exclusionsRejected
        }
        return try await fallbackRoute(from: origin, to: destination, options: options, after: primaryErrors)
    }

    private func fallbackRoute(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions,
        after primaryErrors: [RoutingError]
    ) async throws -> NavigationRoute {
        try Task.checkCancellation()
        do {
            return try await fallback.route(from: origin, to: destination, options: options)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            log.error("Apple Maps failed: \(String(describing: error), privacy: .public)")
            throw Self.combined(primaryErrors + [error as? RoutingError ?? .invalidResponse])
        }
    }

    /// `primary`'s route or error, or `PrimaryTimedOut` after `timeout`, whichever comes first; the other is
    /// cancelled, as is `primary` when the caller is.
    private func primaryRoute(
        _ primary: any RoutingService, timeout: Duration,
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        let outcome = FirstOutcome<NavigationRoute>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outcome.wait(continuation)
                // Not structured, so a request that ignores cancellation can't hold up the fallback.
                outcome.cancelsOnFinish(Task {
                    do {
                        outcome.finish(.success(try await primary.route(from: origin, to: destination,
                                                                        options: options)))
                    } catch {
                        outcome.finish(.failure(error))
                    }
                })
                outcome.cancelsOnFinish(Task { [clock] in
                    do { try await clock.sleep(for: timeout) } catch { return }
                    outcome.finish(.failure(PrimaryTimedOut()))
                })
            }
        } onCancel: {
            outcome.finish(.failure(CancellationError()))
        }
    }

    /// One error for every failure: no route from any server beats rejected exclusions, which beat "unavailable",
    /// which beat a usage limit, which beats a rejected key, which beats a bad response.
    private static func combined(_ errors: [RoutingError]) -> RoutingError {
        if errors.contains(.noRouteFound) { return .noRouteFound }
        if errors.contains(.exclusionsRejected) { return .exclusionsRejected }
        if errors.contains(.serverUnavailable) { return .serverUnavailable }
        if errors.contains(.usageLimitReached) { return .usageLimitReached }
        if errors.contains(.notAuthorized) { return .notAuthorized }
        return .invalidResponse
    }
}

private struct PrimaryTimedOut: Error {}

/// When a primary last timed out or refused us, as time elapsed since, and the refusal (nil for a timeout).
private final class TimeoutMemory: Sendable {
    private let last = Mutex<(since: @Sendable () -> Duration, refusal: RoutingError?)?>(nil)

    /// Nil until the first timeout or refusal.
    var outage: (elapsed: Duration, refusal: RoutingError?)? {
        last.withLock { $0.map { ($0.since(), $0.refusal) } }
    }

    func record(_ elapsed: @escaping @Sendable () -> Duration, refusal: RoutingError?) {
        last.withLock { $0 = (elapsed, refusal) }
    }

    func clear() { last.withLock { $0 = nil } }
}

private extension Clock where Duration == Swift.Duration {
    /// Time elapsed on this clock since now, whatever its instant type.
    func stopwatch() -> @Sendable () -> Swift.Duration {
        let start = now
        return { start.duration(to: now) }
    }
}
