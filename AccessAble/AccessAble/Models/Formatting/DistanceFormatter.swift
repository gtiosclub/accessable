import Foundation
import Observation
import Synchronization

/// Which units walking distances are said and shown in. Saved in the `GuidanceProfile` and
/// changed in Settings.
enum DistanceUnits: String, Codable, CaseIterable, Sendable {
    /// Feet and miles where the phone's region uses them (the US), metres elsewhere.
    case automatic
    case feet
    case metres

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .feet: "Feet and miles"
        case .metres: "Metres and kilometres"
        }
    }

    /// Feet or metres, with automatic decided by `locale`.
    func system(for locale: Locale = .current) -> DistanceFormatter.System {
        switch self {
        case .feet: .imperial
        case .metres: .metric
        case .automatic: locale.measurementSystem == .us ? .imperial : .metric
        }
    }
}

/// The one place walking distances become words, for the voice and the screen alike, so
/// both always use the same unit and rounding. Distances come in as metres.
///
/// Feet are rounded to 25 ft below 500 ft, then tenths of a mile; metres to 10 m below
/// 1 km, then tenths of a kilometre. Finer than that is GPS noise.
struct DistanceFormatter: Hashable, Sendable {
    enum System: Hashable, Sendable {
        case metric
        case imperial
    }

    var system: System

    static let metric = DistanceFormatter(system: .metric)
    static let imperial = DistanceFormatter(system: .imperial)

    /// For speech: "about 150 feet", "about 0.3 miles", "about 80 metres", "about 1.2 kilometres".
    func spoken(_ metres: Double) -> String {
        let amount = amount(metres)
        let unit = amount.value == 1 ? amount.unit.singular : amount.unit.plural
        return "about \(amount.text) \(unit)"
    }

    /// For the screen: "150 ft", "0.3 mi", "80 m", "1.2 km".
    func written(_ metres: Double) -> String {
        let amount = amount(metres)
        return "\(amount.text) \(amount.unit.symbol)"
    }

    private enum Unit {
        case feet, miles, metres, kilometres

        var singular: String {
            switch self {
            case .feet: "foot"
            case .miles: "mile"
            case .metres: "metre"
            case .kilometres: "kilometre"
            }
        }

        var plural: String {
            switch self {
            case .feet: "feet"
            case .miles: "miles"
            case .metres: "metres"
            case .kilometres: "kilometres"
            }
        }

        var symbol: String {
            switch self {
            case .feet: "ft"
            case .miles: "mi"
            case .metres: "m"
            case .kilometres: "km"
            }
        }
    }

    private static let metresPerFoot = 0.3048
    private static let metresPerMile = 1_609.344

    private func amount(_ metres: Double) -> (value: Double, text: String, unit: Unit) {
        let metres = max(0, metres.isFinite ? metres : 0)
        switch system {
        case .imperial:
            let feet = Self.rounded(metres / Self.metresPerFoot, toNearest: 25)
            if feet < 500 { return (feet, Self.text(feet), .feet) }
            let miles = Self.rounded(metres / Self.metresPerMile, toNearest: 0.1)
            return (miles, Self.text(miles), .miles)
        case .metric:
            let rounded = Self.rounded(metres, toNearest: 10)
            if rounded < 1_000 { return (rounded, Self.text(rounded), .metres) }
            let kilometres = Self.rounded(metres / 1_000, toNearest: 0.1)
            return (kilometres, Self.text(kilometres), .kilometres)
        }
    }

    /// Never zero: a walk is always at least one step of rounding.
    private static func rounded(_ value: Double, toNearest step: Double) -> Double {
        max(step, (value / step).rounded() * step)
    }

    /// "25", "0.3", "1"; the same in every region, as speech and tests expect.
    private static func text(_ value: Double) -> String {
        let tenths = (value * 10).rounded()
        return tenths.truncatingRemainder(dividingBy: 10) == 0
            ? String(Int(tenths / 10))
            : String(format: "%.1f", tenths / 10)
    }
}

/// The units the trip, search and "where am I" read when they speak or show a distance.
/// AppViewModel keeps it in step with the profile, the way `AlertSettings` follows the
/// alert filter. Observable, so screens showing a distance redraw when it changes.
@Observable
final class DistanceSettings: Sendable {
    @ObservationIgnored private let state: Mutex<DistanceUnits>

    init(units: DistanceUnits = .automatic) {
        state = Mutex(units)
    }

    var units: DistanceUnits {
        get {
            access(keyPath: \.units)
            return state.withLock { $0 }
        }
        set {
            withMutation(keyPath: \.units) {
                state.withLock { $0 = newValue }
            }
        }
    }

    var formatter: DistanceFormatter { DistanceFormatter(system: units.system()) }
}
