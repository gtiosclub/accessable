import Foundation

/// Global power/quality mode. Owned by the AnnouncementEngine side (3.3);
/// the camera (1.4) and location (2.1) pipelines subscribe and adapt.
enum PerformanceMode: String, Codable, CaseIterable, Sendable {
    case normal
    case battery

    /// Process every Nth camera frame.
    var detectionFrameStride: Int {
        switch self {
        case .normal: 2   // ~15 fps out of 30
        case .battery: 3  // ~10 fps out of 30
        }
    }

    /// Whether ARKit scene reconstruction (mesh classification) should run.
    var meshReconstructionEnabled: Bool { self == .normal }
}

/// What the user picked in Settings. `.automatic` follows Low Power Mode and thermal state.
enum PerformanceModeSetting: String, Codable, CaseIterable, Sendable {
    case automatic
    case normal
    case battery

    func resolve(isLowPowerModeEnabled: Bool, thermalState: ProcessInfo.ThermalState) -> PerformanceMode {
        switch self {
        case .normal: return .normal
        case .battery: return .battery
        case .automatic:
            if isLowPowerModeEnabled { return .battery }
            switch thermalState {
            case .serious, .critical: return .battery
            default: return .normal
            }
        }
    }
}
