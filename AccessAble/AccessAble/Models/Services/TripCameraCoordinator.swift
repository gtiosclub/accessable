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
                do {
                    try await scene.start()
                    holdsCamera = true
                } catch {
                    log.error("No obstacle detection on this trip: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                await scene.stop()
                holdsCamera = false
            }
        }
        if holdsCamera { await scene.stop() }
    }
}
