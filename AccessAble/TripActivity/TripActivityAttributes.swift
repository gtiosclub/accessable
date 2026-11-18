import ActivityKit
import Foundation

/// Owner: Maps + Location (2.x). The trip shown on the lock screen and in the Dynamic Island.
/// Shared by the app, which starts and updates the activity, and the widget, which draws it,
/// so it uses only ActivityKit and Foundation types.
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Status: String, Codable, Hashable {
            case active, paused, offRoute, arrived
        }

        var status: Status
        var instruction: String
        /// Written distance to the next turn, e.g. "150 ft", already in the user's units; nil when
        /// off route or arrived. The app formats it so voice and screen share one formatter.
        var distance: String?
        /// SF Symbol for the next turn. The app maps its maneuver to this, since the widget
        /// can't see the app's types.
        var symbolName: String
        var arrival: Date?
    }

    var destinationName: String
}
