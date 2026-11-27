import Foundation
import os

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

    func run() async {
        /// Whether geo-tracking was asked for with the camera held; nil while it isn't held.
        var held: Bool?
        /// Apple's answer for this trip, kept once it is in; nil until then, so the next start asks again.
        var canGeoTrack: Bool?
        var holdsRecovery = false
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
                } catch {
                    log.error("No obstacle detection on this trip: \(error.localizedDescription, privacy: .public)")
                }
            } else if !wantsCamera, let geoTracking = held {
                if holdsRecovery { recovery?.release() }
                holdsRecovery = false
                await camera.stop(geoTracking: geoTracking)
                held = nil
            }
            // the next trip may start somewhere else
            if state.phase == .planning || state.phase == .arrived { canGeoTrack = nil }
        }
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
}
