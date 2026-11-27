#if DEBUG
import Foundation

/// Fixtures for Maps previews only.
enum MapsPreviewData {
    static let place = SamplePlace(
        id: "culc", name: "Clough Undergraduate Learning Commons", address: "266 4th St NW, Atlanta, GA 30313",
        category: .labeledPlaces, rating: 4.0, reviewCount: 19, recordedRouteCount: 1,
        isSaved: false, isRecent: false, latitude: 33.7749, longitude: -84.3964
    )

    static let announcements: [TripAnnouncement] = [
        TripAnnouncement(text: "Walk straight for 10 min; turn left", kind: .info),
        TripAnnouncement(text: "Stop and move left; pillar in front", kind: .warning),
    ]
}
#endif
