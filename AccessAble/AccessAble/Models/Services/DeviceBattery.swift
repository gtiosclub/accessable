import UIKit

/// The battery as `UIDevice` reports it.
struct DeviceBattery: BatteryReading {
    @MainActor
    func status() async -> BatteryStatus {
        let device = UIDevice.current
        // without it the level is always -1 and the state unknown
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        return BatteryStatus(level: level < 0 ? nil : level,
                             isChargingOrFull: device.batteryState == .charging || device.batteryState == .full)
    }
}
