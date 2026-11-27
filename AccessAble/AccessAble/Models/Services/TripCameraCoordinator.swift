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
    /// Wall clock for the hold-up prompt cooldown; tests inject a `ManualDate`.
    var now: @Sendable () -> Date = { .now }

    func run() async {
        /// Whether geo-tracking was asked for with the camera held; nil while it isn't held.
        var held: Bool?
        /// Apple's answer for this trip, kept once it is in; nil until then, so the next start asks again.
        var canGeoTrack: Bool?
        var holdsRecovery = false
        var geoWatch: GeoWatch?
        // for the whole run, so the hold-up prompt's cooldown outlasts camera restarts, pauses and trips
        var coach = GeoAimingCoach()
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
                    geoWatch = watchGeo(geoTracking: geoTracking)
                } catch {
                    log.error("No obstacle detection on this trip: \(error.localizedDescription, privacy: .public)")
                }
            } else if !wantsCamera, let geoTracking = held {
                geoWatch?.task.cancel()
                geoWatch = nil
                if holdsRecovery { recovery?.release() }
                holdsRecovery = false
                await camera.stop(geoTracking: geoTracking)
                held = nil
            }
            // the next trip may start somewhere else
            if state.phase == .planning || state.phase == .arrived { canGeoTrack = nil }
            await promptToAim(state, coach: &coach, geo: geoWatch?.latest)
        }
        geoWatch?.task.cancel()
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

    /// Keeps the latest geo update for the AR-5 hold-up prompt while the trip holds the camera with geo-tracking.
    private func watchGeo(geoTracking: Bool) -> GeoWatch? {
        guard geoTracking, announcements != nil, phoneAimingHelp != nil, let geo = camera.geoTracking else {
            return nil
        }
        let latest = LatestGeo()
        let task = Task {
            for await update in geo.geoTrackingUpdates() { latest.value.withLock { $0 = update } }
        }
        return GeoWatch(latest: latest, task: task)
    }

    /// The AR-5 hold-up prompt, given on trip updates only, so it follows the trip's own cues for the same update.
    private func promptToAim(_ state: TripState, coach: inout GeoAimingCoach, geo: LatestGeo?) async {
        guard state.phase == .active, let geo, let announcements, let phoneAimingHelp else {
            coach.tripEnded()
            return
        }
        let update = geo.value.withLock { $0 }
        if let event = coach.update(enabled: phoneAimingHelp(), geo: update, trip: state, now: now()) {
            await announcements.submit(event)
        }
    }
}

private struct GeoWatch {
    let latest: LatestGeo
    let task: Task<Void, Never>
}

/// Latest geo update, written by the watching task and read on trip updates.
private final class LatestGeo: Sendable {
    let value = Mutex<GeoTrackingUpdate?>(nil)
}
