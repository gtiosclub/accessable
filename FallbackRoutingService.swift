import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "Routing")

/// Asks `primary` (Valhalla) first and, when it fails or takes longer than `timeout`, `fallback` (Apple Maps), telling
/// the user that the backup route may include stairs. Cancellation is passed on, never treated as a failure.
struct FallbackRoutingService: RoutingService {
    static let backupNotice = "Using backup directions. They may include stairs."
    static let defaultTimeout: Duration = .seconds(6)

    private let primary: any RoutingService
    private let fallback: any RoutingService
    private let announcements: any AnnouncementSink
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `sleep` waits out the timeout; tests replace it so they don't wait in real time.
    init(
        primary: any RoutingService,
        fallback: any RoutingService,
        announcements: any AnnouncementSink,
        timeout: Duration = FallbackRoutingService.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.announcements = announcements
        self.timeout = timeout
        self.sleep = sleep
    }

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        let primaryError: RoutingError?
        switch await primaryOutcome(from: origin, to: destination, options: options) {
        case .route(let route):
            return route
        case .failed(let error):
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            log.error("Valhalla failed, trying Apple Maps: \(String(describing: error), privacy: .public)")
            primaryError = error as? RoutingError ?? .invalidResponse
        case .timedOut:
            log.error("Valhalla took longer than \(String(describing: timeout), privacy: .public), trying Apple Maps")
            primaryError = nil
        }
        try Task.checkCancellation()

        let route: NavigationRoute
        do {
            route = try await fallback.route(from: origin, to: destination, options: options)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            log.error("Apple Maps failed too: \(String(describing: error), privacy: .public)")
            throw Self.combined(primaryError, error as? RoutingError ?? .invalidResponse)
        }
        try Task.checkCancellation()

        let time = Date.now
        await announcements.submit(AnnouncementEvent(
            category: .system, priority: .high, text: Self.backupNotice, haptic: .attention, source: .navigation,
            createdAt: time, expiresAt: time.addingTimeInterval(30)
        ))
        return route
    }

    private enum PrimaryOutcome: Sendable {
        case route(NavigationRoute)
        case failed(any Error)
        case timedOut
    }

    /// The primary's answer or the timeout, whichever comes first; the other is cancelled.
    private func primaryOutcome(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async -> PrimaryOutcome {
        await withTaskGroup(of: PrimaryOutcome.self) { group in
            group.addTask { [primary] in
                do {
                    return .route(try await primary.route(from: origin, to: destination, options: options))
                } catch {
                    return .failed(error)
                }
            }
            group.addTask { [sleep, timeout] in
                do {
                    try await sleep(timeout)
                    return .timedOut
                } catch {
                    // only cancelled: by the caller, or because the primary answered first
                    return .failed(CancellationError())
                }
            }
            let first = await group.next() ?? .failed(CancellationError())
            group.cancelAll()
            return first
        }
    }

    /// One error for both failures: no route from either beats "unavailable", which beats a bad response.
    private static func combined(_ primary: RoutingError?, _ fallback: RoutingError) -> RoutingError {
        let errors = [primary, fallback].compactMap { $0 }
        if errors.contains(.noRouteFound) { return .noRouteFound }
        if errors.contains(.serverUnavailable) { return .serverUnavailable }
        return .invalidResponse
    }
}
