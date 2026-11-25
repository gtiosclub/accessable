import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "AccessAble", category: "Routing")

/// Asks `primary` (Valhalla) first and, when it fails or takes longer than `timeout`, `fallback` (Apple Maps), whose
/// routes come back with `source` `.appleMaps` for the caller to tell the user. Cancellation is passed on, never
/// treated as a failure.
///
/// Apple Maps can't avoid places, so a request that excludes some never falls back: a failure or timeout throws
/// `.exclusionsRejected` instead, for `ReportAwareRoutingService` to try again with fewer exclusions. Its last try has
/// none, so a route it gets from Apple Maps still lists the reports it passes.
struct FallbackRoutingService: RoutingService {
    static let defaultTimeout: Duration = .seconds(6)
    /// After a timeout, how long requests without exclusions skip Valhalla, so each reroute doesn't wait it out again.
    static let timeoutMemory: Duration = .seconds(120)

    private let primary: any RoutingService
    private let fallback: any RoutingService
    private let timeout: Duration
    private let clock: any Clock<Duration>
    /// The primary's last timeout on a request without exclusions. Shared by copies.
    private let lastTimeout = TimeoutMemory()

    init(
        primary: any RoutingService,
        fallback: any RoutingService,
        timeout: Duration = FallbackRoutingService.defaultTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.primary = primary
        self.fallback = fallback
        self.timeout = timeout
        self.clock = clock
    }

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        let excludes = !options.excludeLocations.isEmpty || !options.excludePolygons.isEmpty
        if !excludes, let elapsed = lastTimeout.elapsed, elapsed < Self.timeoutMemory {
            log.notice("Valhalla timed out \(String(describing: elapsed), privacy: .public) ago, asking Apple Maps")
            return try await fallbackRoute(from: origin, to: destination, options: options, after: nil)
        }

        let primaryError: RoutingError?
        do {
            return try await primaryRoute(from: origin, to: destination, options: options)
        } catch is CancellationError where Task.isCancelled {
            throw CancellationError()
        } catch is PrimaryTimedOut {
            log.error("Valhalla took longer than \(String(describing: timeout), privacy: .public)")
            guard !excludes else { throw RoutingError.exclusionsRejected }
            lastTimeout.record(clock.stopwatch())
            primaryError = nil
        } catch {
            log.error("Valhalla failed: \(String(describing: error), privacy: .public)")
            let routingError = error as? RoutingError ?? .invalidResponse
            if excludes {
                // no route at all is the answer; anything else may be the exclusions' fault, so fewer can be tried
                throw routingError == .noRouteFound ? routingError : RoutingError.exclusionsRejected
            }
            primaryError = routingError
        }
        return try await fallbackRoute(from: origin, to: destination, options: options, after: primaryError)
    }

    private func fallbackRoute(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions,
        after primaryError: RoutingError?
    ) async throws -> NavigationRoute {
        try Task.checkCancellation()
        do {
            return try await fallback.route(from: origin, to: destination, options: options)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            log.error("Apple Maps failed: \(String(describing: error), privacy: .public)")
            throw Self.combined(primaryError, error as? RoutingError ?? .invalidResponse)
        }
    }

    /// The primary's route or error, or `PrimaryTimedOut` after `timeout`, whichever comes first; the other is
    /// cancelled, as is the primary when the caller is.
    private func primaryRoute(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        let outcome = FirstOutcome<NavigationRoute>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outcome.wait(continuation)
                // Not structured, so a request that ignores cancellation can't hold up the fallback.
                outcome.cancelsOnFinish(Task { [primary] in
                    do {
                        outcome.finish(.success(try await primary.route(from: origin, to: destination,
                                                                        options: options)))
                    } catch {
                        outcome.finish(.failure(error))
                    }
                })
                outcome.cancelsOnFinish(Task { [clock, timeout] in
                    do { try await clock.sleep(for: timeout) } catch { return }
                    outcome.finish(.failure(PrimaryTimedOut()))
                })
            }
        } onCancel: {
            outcome.finish(.failure(CancellationError()))
        }
    }

    /// One error for both failures: no route from either beats rejected exclusions, which beat "unavailable", which
    /// beats a bad response.
    private static func combined(_ primary: RoutingError?, _ fallback: RoutingError) -> RoutingError {
        let errors = [primary, fallback].compactMap { $0 }
        if errors.contains(.noRouteFound) { return .noRouteFound }
        if errors.contains(.exclusionsRejected) { return .exclusionsRejected }
        if errors.contains(.serverUnavailable) { return .serverUnavailable }
        return .invalidResponse
    }
}

private struct PrimaryTimedOut: Error {}

/// When the primary last timed out, as time elapsed since.
private final class TimeoutMemory: Sendable {
    private let since = Mutex<(@Sendable () -> Duration)?>(nil)

    /// Nil until the first timeout.
    var elapsed: Duration? { since.withLock { $0?() } }

    func record(_ elapsed: @escaping @Sendable () -> Duration) { since.withLock { $0 = elapsed } }
}

private extension Clock where Duration == Swift.Duration {
    /// Time elapsed on this clock since now, whatever its instant type.
    func stopwatch() -> @Sendable () -> Swift.Duration {
        let start = now
        return { start.duration(to: now) }
    }
}
