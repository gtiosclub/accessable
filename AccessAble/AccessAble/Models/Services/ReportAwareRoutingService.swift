import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "Routing")

/// Routes around active community reports. Reports are best effort: if they can't be fetched in time, or no route
/// avoids them, the route goes without and lists the reports it passes in `unavoidedReports`.
struct ReportAwareRoutingService: RoutingService {
    /// How long a route request waits for reports before going without them.
    static let reportTimeout: Duration = .seconds(2)
    /// Metres beyond the trip's ends that reports are fetched for, since a route can bend away from the straight line.
    static let searchMargin: Double = 500
    /// Metres from the start or the end within which reports are dropped first when no route avoids them all: a
    /// report the user is standing at can't be routed around.
    static let endpointClearance: Double = 25
    /// Between attempts, for the public Valhalla server's fair use of about one request a second.
    static let retrySpacing: Duration = .seconds(1)

    let base: any RoutingService
    private let reports: any ReportService
    private let clock: any Clock<Duration>

    init(base: any RoutingService, reports: any ReportService, clock: any Clock<Duration> = ContinuousClock()) {
        self.base = base
        self.reports = reports
        self.clock = clock
    }

    /// Tries all the reports, then without those at either end, then none, stopping at the first route found. The
    /// reports are those fetched and those in `options.reports`, which go through the same steps even when the fetch
    /// fails, and aren't passed on to `base`.
    func route(
        from origin: GeoCoordinate,
        to destination: GeoCoordinate,
        options: RouteOptions
    ) async throws -> NavigationRoute {
        var options = options
        let given = options.reports
        options.reports = []
        guard origin != destination else {
            return try await base.route(from: origin, to: destination, options: options)
        }
        let center = GeoCoordinate(
            latitude: (origin.latitude + destination.latitude) / 2,
            longitude: (origin.longitude + destination.longitude) / 2
        )
        let radius = GeoMath.distance(from: origin, to: destination) / 2 + Self.searchMargin
        // a fetched copy is the newer one
        let fetched = try await activeReports(near: center, radius: radius) ?? []
        let fetchedIDs = Set(fetched.map(\.id))
        let nearby = fetched + given.filter { !fetchedIDs.contains($0.id) }
        guard !nearby.isEmpty else {
            return try await base.route(from: origin, to: destination, options: options)
        }

        let all = ReportExclusions.make(from: nearby, origin: origin, destination: destination, adding: options)
        if all.excluded.count < nearby.count {
            log.notice("Excluding \(all.excluded.count, privacy: .public) of \(nearby.count, privacy: .public) reports, within Valhalla's limits")
        }
        let awayFromEnds = ReportExclusions.make(
            from: nearby.filter {
                !$0.isNear(origin, within: Self.endpointClearance)
                    && !$0.isNear(destination, within: Self.endpointClearance)
            },
            origin: origin, destination: destination, adding: options
        )
        var attempts: [ReportExclusions] = []
        for exclusions in [all, awayFromEnds]
        where exclusions.options != options && !attempts.contains(where: { $0.options == exclusions.options }) {
            attempts.append(exclusions)
        }

        for exclusions in attempts {
            do {
                return try await route(from: origin, to: destination, excluding: exclusions, among: nearby)
            } catch let error as RoutingError where error == .noRouteFound || error == .exclusionsRejected {
                log.notice("No route excluding \(exclusions.excluded.count, privacy: .public) reports: \(String(describing: error), privacy: .public)")
                try await clock.sleep(for: Self.retrySpacing)
            }
        }
        log.notice("Routing without reports")
        return try await route(
            from: origin, to: destination, excluding: ReportExclusions(options: options, excluded: []), among: nearby
        )
    }

    private func route(
        from origin: GeoCoordinate,
        to destination: GeoCoordinate,
        excluding exclusions: ReportExclusions,
        among nearby: [Report]
    ) async throws -> NavigationRoute {
        var route = try await base.route(from: origin, to: destination, options: exclusions.options)
        let excluded = Set(exclusions.excluded.map(\.id))
        route.unavoidedReports = ReportExclusions.reports(nearby.filter { !excluded.contains($0.id) }, passedBy: route)
        return route
    }

    /// The active reports, or nil if they couldn't be fetched within `reportTimeout`.
    /// - Throws: `CancellationError` if the task is cancelled.
    private func activeReports(near center: GeoCoordinate, radius: Double) async throws -> [Report]? {
        let outcome = FirstOutcome<[Report]>()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    outcome.wait(continuation)
                    // Not structured, so a fetch that ignores cancellation can't hold up the route.
                    outcome.cancelsOnFinish(Task { [reports] in
                        do {
                            outcome.finish(.success(try await reports.reports(near: center, radius: radius)))
                        } catch {
                            outcome.finish(.failure(error))
                        }
                    })
                    outcome.cancelsOnFinish(Task { [clock] in
                        do { try await clock.sleep(for: Self.reportTimeout) } catch { return }
                        outcome.finish(.failure(ReportFetchTimedOut()))
                    })
                }
            } onCancel: {
                outcome.finish(.failure(CancellationError()))
            }
        } catch is CancellationError where Task.isCancelled {
            throw CancellationError()
        } catch ReportServiceError.notSignedIn {
            log.info("Routing without reports: not signed in")
        } catch is ReportFetchTimedOut {
            log.notice("Routing without reports: they didn't arrive in time")
        } catch {
            log.error("Routing without reports: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }
}

private struct ReportFetchTimedOut: Error {}
