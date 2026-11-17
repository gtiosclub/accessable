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
        /// `distance` in words, e.g. "150 feet", for VoiceOver, which can misread "mi" and "km".
        var spokenDistance: String?
        /// SF Symbol for the next turn. The app maps its maneuver to this, since the widget
        /// can't see the app's types.
        var symbolName: String
        var arrival: Date?
    }

    var destinationName: String
}

extension TripActivityAttributes.ContentState {
    /// What VoiceOver reads for the whole activity, so the turn and its distance are heard as one
    /// sentence: "Turn left onto Ferst Drive, in 150 feet. Arrive at 3:42 PM."
    func accessibilityLabel(
        destinationName: String, arrivalTime: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .shortened)
    ) -> String {
        // routing instructions may already end in a full stop
        let instruction = instruction.hasSuffix(".") ? String(instruction.dropLast()) : instruction
        switch status {
        case .active:
            let turn = spokenDistance.map { "\(instruction), in \($0)." } ?? "\(instruction)."
            guard let arrival else { return turn }
            return "\(turn) Arrive at \(arrival.formatted(arrivalTime))."
        case .paused:
            return "Paused. \(instruction)."
        case .offRoute:
            return "\(instruction)."
        case .arrived:
            return "Arrived at \(destinationName)."
        }
    }
}
