import Foundation

/// The user's walking route choices. Each is a preference Valhalla weighs, not a guarantee: a route still uses
/// stairs, say, when there's no other way.
struct RoutePreferences: Codable, Equatable, Sendable {
    enum WalkingSpeed: String, Codable, CaseIterable, Sendable {
        case slow, normal, fast

        var metresPerSecond: Double {
            switch self {
            case .slow: 0.9
            case .normal: 1.2
            case .fast: 1.5
            }
        }
    }

    var avoidStairs = false
    var avoidElevators = false
    var avoidSteepHills = false
    var preferWellLit = false
    var preferFootpaths = false
    var avoidAlleysAndDriveways = false
    var avoidServiceRoads = false
    var avoidUnpavedPaths = false
    var walkingSpeed: WalkingSpeed = .normal

    /// Valhalla's pedestrian costing for these choices; with every choice off, exactly `RouteOptions()`.
    /// The elevator and service road values are suggested rather than measured, and campus OSM ways may not
    /// be tagged with lighting, so `useLit` is untested here.
    var routeOptions: RouteOptions {
        var options = RouteOptions()
        options.walkingSpeed = walkingSpeed.metresPerSecond
        if avoidStairs { options.stepPenalty = 3600 }
        if avoidElevators { options.elevatorPenalty = 3600 }
        if avoidSteepHills { options.useHills = 0 }
        if preferWellLit { options.useLit = 1 }
        if preferFootpaths {
            options.walkwayFactor = 0.8
            options.sidewalkFactor = 0.8
        }
        if avoidAlleysAndDriveways {
            options.alleyFactor = 5
            options.drivewayFactor = 10
        }
        if avoidServiceRoads {
            options.servicePenalty = 60
            options.serviceFactor = 3
        }
        if avoidUnpavedPaths {
            options.useTracks = 0
            options.maxHikingDifficulty = 0
        }
        return options
    }
}

extension RoutePreferences {
    /// Keys missing from older or newer data take their defaults.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RoutePreferences()
        func flag(_ key: CodingKeys, _ fallback: Bool) throws -> Bool {
            try container.decodeIfPresent(Bool.self, forKey: key) ?? fallback
        }
        avoidStairs = try flag(.avoidStairs, defaults.avoidStairs)
        avoidElevators = try flag(.avoidElevators, defaults.avoidElevators)
        avoidSteepHills = try flag(.avoidSteepHills, defaults.avoidSteepHills)
        preferWellLit = try flag(.preferWellLit, defaults.preferWellLit)
        preferFootpaths = try flag(.preferFootpaths, defaults.preferFootpaths)
        avoidAlleysAndDriveways = try flag(.avoidAlleysAndDriveways, defaults.avoidAlleysAndDriveways)
        avoidServiceRoads = try flag(.avoidServiceRoads, defaults.avoidServiceRoads)
        avoidUnpavedPaths = try flag(.avoidUnpavedPaths, defaults.avoidUnpavedPaths)
        walkingSpeed = try container.decodeIfPresent(WalkingSpeed.self, forKey: .walkingSpeed) ?? defaults.walkingSpeed
    }
}
