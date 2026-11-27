import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "AccessAble", category: "TripCamera")

/// Joins Maps and Computer Vision: keeps the camera pipeline running for as long as a trip is
/// being walked, whichever screen is open, so obstacle warnings come with the turns.
/// Runs until its task is cancelled or the trip stream ends.
struct TripCameraCoordinator: Sendable {
    let trip: any TripStateProviding
    let camera: TripCamera
    /// Restarts guidance that stops while the trip holds the camera, with the map showing too;
    /// nil leaves a stopped session as it is.
    var recovery: GuidanceRecovery?
    var announcements: (any AnnouncementSink)?
    /// Whether Settings → Phone Aiming Help is on; nil skips the AR-5 hold-up prompt.
    var phoneAimingHelp: (@Sendable () -> Bool)?
    /// Wall clock for the hold-up prompt cooldown; tests inject a fixed clock.
    var now: @Sendable () -> Date = { .now }

    func run() async {
        /// Whether geo-tracking was asked for with the camera held; nil while it isn't held.
        var held: Bool?
        /// Apple's answer for this trip, kept once it is in; nil until then, so the next start asks again.
        var canGeoTrack: Bool?
        var holdsRecovery = false
        var aimingTask: Task<Void, Never>?
        for await state in trip.tripStates() {
            // between trips, so the answer is in before the next one opens the camera
            if state.phase == .planning { await camera.prepare() }
            let wantsCamera = state.phase == .active
            if wantsCamera, held == nil {
                if canGeoTrack == nil { canGeoTrack = await camera.canGeoTrack() }
                let geoTracking = canGeoTrack ?? false
                do {
                    try await camera.start(geoTracking: geoTracking)
                    held = geoTracking
                    holdsRecovery = holdRecovery()
                    aimingTask = startAimingHelp(geoTracking: geoTracking)
                } catch {
                    log.error("No obstacle detection on this trip: \(error.localizedDescription, privacy: .public)")
                }
            } else if !wantsCamera, let geoTracking = held {
                aimingTask?.cancel()
                aimingTask = nil
                if holdsRecovery { recovery?.release() }
                holdsRecovery = false
                await camera.stop(geoTracking: geoTracking)
                held = nil
            }
            // the next trip may start somewhere else
            if state.phase == .planning || state.phase == .arrived { canGeoTrack = nil }
        }
        aimingTask?.cancel()
        if holdsRecovery { recovery?.release() }
        if let geoTracking = held { await camera.stop(geoTracking: geoTracking) }
    }

    /// Whether the recovery was held, so it is released with the camera.
    private func holdRecovery() -> Bool {
        guard let recovery, let announcements, let provider = camera.scene as? any GuidanceStatusProviding else {
            return false
        }
        recovery.hold(provider, announcements: announcements)
        return true
    }

    /// Watches trip state and geo updates for the AR-5 hold-up prompt while the trip holds the camera.
    private func startAimingHelp(geoTracking: Bool) -> Task<Void, Never>? {
        guard geoTracking, let announcements, let phoneAimingHelp,
              let geo = camera.geoTracking else { return nil }
        let trip = trip
        let now = now
        return Task {
            // Heap box so both child tasks can share the latest update under Swift 6 sending rules.
            let latestGeo = LatestGeo()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [latestGeo] in
                    for await update in geo.geoTrackingUpdates() {
                        guard !Task.isCancelled else { return }
                        latestGeo.value.withLock { $0 = update }
                    }
                }
                group.addTask { [latestGeo] in
                    var coach = GeoAimingCoach()
                    for await state in trip.tripStates() {
                        guard !Task.isCancelled else { return }
                        if state.phase != .active {
                            coach.tripEnded()
                            continue
                        }
                        let geoUpdate = latestGeo.value.withLock { $0 }
                        if let event = coach.update(
                            enabled: phoneAimingHelp(),
                            tripActive: true,
                            geo: geoUpdate,
                            trip: state,
                            now: now()
                        ) {
                            await announcements.submit(event)
                        }
                    }
                }
                await group.next()
                group.cancelAll()
            }
        }
    }
}

/// Latest geo update shared by the AR-5 aiming watchers.
private final class LatestGeo: Sendable {
    let value = Mutex<GeoTrackingUpdate?>(nil)
}
