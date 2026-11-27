import CoreMotion
import Foundation

/// Live gravity readings from `CMMotionManager`.
final class CoreMotionDeviceMotion: DeviceMotionProviding, @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "AccessAble.DeviceMotion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    func gravitySamples() -> AsyncStream<DeviceGravitySample> {
        AsyncStream { continuation in
            guard manager.isDeviceMotionAvailable else {
                continuation.finish()
                return
            }
            manager.deviceMotionUpdateInterval = 1.0 / 20.0
            manager.startDeviceMotionUpdates(to: queue) { motion, _ in
                guard let motion else { return }
                continuation.yield(DeviceGravitySample(gravityZ: motion.gravity.z, timestamp: .now))
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    private func stop() {
        manager.stopDeviceMotionUpdates()
    }
}