import Foundation

/// Opens the shared camera for a trip (AR-2): asks for geo-tracking where Apple has imagery, then starts the scene.
/// The trip screen and `TripCameraCoordinator` both open it this way, because whichever starts the camera first
/// decides its tracking; a later start joins the running session as it is.
struct TripCamera: Sendable {
    let scene: any SceneObservationProviding
    /// nil where the camera can't geo-track (the sample scene).
    let geoTracking: (any GeoTrackingProviding)?
    /// Whether Apple has geo-tracking imagery here. Capped, since the camera waits on it.
    let isGeoTrackingAvailableHere: @Sendable () async -> Bool

    /// Starts Apple's availability check in the background, so `canGeoTrack()` needn't wait on it.
    func prepare() async {
        await geoTracking?.prepareGeoTracking()
    }

    /// Whether this trip can geo-track. Ask once per trip and pass the answer to `start(geoTracking:)`.
    func canGeoTrack() async -> Bool {
        guard let geoTracking else { return false }
        // found by prepare() before the trip, so obstacle warnings don't wait on Apple
        if let known = await geoTracking.knownGeoAvailability() { return known }
        return await isGeoTrackingAvailableHere()
    }

    /// Asks for geo-tracking when `wanted`, then starts the scene. A start that succeeds needs a
    /// `stop(geoTracking:)` with the same `wanted`; one that throws has already given geo-tracking back.
    func start(geoTracking wanted: Bool) async throws {
        let geoTracking = wanted ? geoTracking : nil
        // before start(), since a running session keeps its tracking
        await geoTracking?.setGeoTrackingWanted(true)
        do {
            try await scene.start()
        } catch {
            await geoTracking?.setGeoTrackingWanted(false)
            throw error
        }
    }

    func stop(geoTracking wanted: Bool) async {
        await scene.stop()
        if wanted { await geoTracking?.setGeoTrackingWanted(false) }
    }
}
