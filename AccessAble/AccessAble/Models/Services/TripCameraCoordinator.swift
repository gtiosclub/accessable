import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "TripCamera")

/// Joins Maps and Computer Vision: keeps the camera pipeline running for as long as a trip is
/// being walked, whichever screen is open, so obstacle warnings come with the turns.
/// Runs until its task is cancelled or the trip stream ends.
struct TripCameraCoordinator: Sendable {
    let trip: any TripStateProviding
    let scene: any SceneObservationProviding

    func run() async {
        var holdsCamera = false
        for await state in trip.tripStates() {
            let wantsCamera = state.phase == .active
            guard wantsCamera != holdsCamera else { continue }
            if wantsCamera {
                // before start(), since a running session keeps its tracking
                await geoTracking?.setGeoTrackingWanted(true)
                do {
                    try await scene.start()
                    holdsCamera = true
                } catch {
                    log.error("No obstacle detection on this trip: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                await scene.stop()
                holdsCamera = false
                await geoTracking?.setGeoTrackingWanted(false)
            }
        }
        if holdsCamera {
            await scene.stop()
            await geoTracking?.setGeoTrackingWanted(false)
        }
    }

    /// Trips geo-track where they can (AR-2), for a sharper position than GPS.
    private var geoTracking: (any GeoTrackingProviding)? { scene as? any GeoTrackingProviding }
}
