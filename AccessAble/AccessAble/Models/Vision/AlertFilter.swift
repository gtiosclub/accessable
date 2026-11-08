import Foundation
import Synchronization

/// How much harm walking into something can do. Owner: Computer Vision (1.1).
///
/// The user sets a bar (`AlertFilter.minimumDanger`) and only hears about things at or
/// above it, so a cluttered room does not turn into a stream of chairs and laptops.
enum DangerLevel: Int, Codable, CaseIterable, Comparable, Sendable {
    /// Nice to know: crowds, small things on a table, camera hints.
    case low = 1
    /// Something to bump into: furniture, bags, a person standing in the way.
    case medium
    /// Hard and easy to walk into: poles, hydrants, kerbs, anything unnamed in the path.
    case high
    /// Can hurt badly: vehicles, steps down, drop-offs.
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var displayName: String {
        switch self {
        case .low: "Everything"
        case .medium: "Medium and above"
        case .high: "High and above"
        case .critical: "Critical only"
        }
    }

    /// What a detection is worth warning about. Anything without a known label, including
    /// the geometry's unnamed obstacles, counts as high: it could be a pole.
    init(of detection: Detection) {
        self = Self.byLabel[detection.label.lowercased()] ?? .high
    }

    init(of hazard: ElevationHazardType) {
        self = switch hazard {
        case .dropOff, .stepDown: .critical
        case .stepUp: .high
        case .unknown: .low
        }
    }

    /// Something moving toward the user (T34): vehicles are critical, people medium.
    init(approaching label: String) {
        self = Self.vehicles.contains(label.lowercased()) ? .critical : .medium
    }

    private static let vehicles: Set<String> = ["bicycle", "bus", "car", "motorcycle", "train", "truck"]

    private static let byLabel: [String: DangerLevel] = {
        var levels: [String: DangerLevel] = [:]
        for label in vehicles { levels[label] = .critical }
        for label in ["fire hydrant", "parking meter", "stop sign", "traffic light", "wall", Detection.obstacleLabel] {
            levels[label] = .high
        }
        for label in ["bench", "chair", "couch", "dining table", "bed", "potted plant", "suitcase",
                      "backpack", "handbag", "person", "dog", "toilet", "refrigerator", "tv", "crosswalk"] {
            levels[label] = .medium
        }
        for label in ["laptop", "cell phone", "book", "cup", "bottle", "keyboard", "mouse", "remote",
                      "door", "window"] {
            levels[label] = .low
        }
        return levels
    }()
}

/// What the user wants to be warned about: things at least this dangerous, at most this far
/// away. Set on the Live detection screen and saved in the `GuidanceProfile`.
///
/// Two things always get through, whatever the setting: a drop-off, and anything in the
/// path inside the "Stop" distance. Neither is safe to filter out.
struct AlertFilter: Codable, Hashable, Sendable {
    var minimumDanger: DangerLevel = .medium
    /// The first warning comes at this distance, in metres.
    var maximumDistance: Float = 2.5

    /// The distances offered on the Live screen.
    static let distanceChoices: [Float] = [1.5, 2.5, 4]

    static let `default` = AlertFilter()

    func allows(_ level: DangerLevel) -> Bool { level >= minimumDanger }
}

/// The filter the camera pipeline reads each frame. AppViewModel keeps it in step with the
/// profile, the way `AskAISettings` follows the Ask AI ranking.
final class AlertSettings: Sendable {
    private let state = Mutex(AlertFilter.default)
    private let tones = Mutex(false)

    init(filter: AlertFilter = .default) {
        state.withLock { $0 = filter }
    }

    var filter: AlertFilter {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    /// Whether steering tones play (`SteeringCue`): the profile's spatial audio channel.
    var soundCues: Bool {
        get { tones.withLock { $0 } }
        set { tones.withLock { $0 = newValue } }
    }
}
