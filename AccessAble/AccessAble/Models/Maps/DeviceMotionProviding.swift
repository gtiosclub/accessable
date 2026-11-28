import Foundation

struct DeviceGravitySample: Equatable, Sendable {
    let gravityZ: Double
    let timestamp: Date
}

/// Feeds device gravity for "phone flat" detection; fake in tests.
protocol DeviceMotionProviding: Sendable {
    func gravitySamples() -> AsyncStream<DeviceGravitySample>
}