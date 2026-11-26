import Foundation
import UIKit

@MainActor
protocol ScreenAwakeControlling: AnyObject { func setAwake(_ awake: Bool) }

/// All call screens share one set of requests. One disappearing screen cannot release
/// another screen's request, and a pre-existing Maps idle-timer setting is restored.
@MainActor
final class ScreenAwakeCoordinator {
    static let shared = ScreenAwakeCoordinator(
        read: { UIApplication.shared.isIdleTimerDisabled },
        write: { UIApplication.shared.isIdleTimerDisabled = $0 }
    )
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private var requests: Set<UUID> = []
    private var previous: Bool?

    init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
        self.read = read
        self.write = write
    }

    func setAwake(_ awake: Bool, for id: UUID) {
        if awake {
            if requests.isEmpty { previous = read() }
            requests.insert(id)
            write(true)
        } else {
            guard requests.remove(id) != nil else { return }
            if requests.isEmpty, let previous {
                write(previous)
                self.previous = nil
            }
        }
    }
}

@MainActor
final class ScreenAwakeController: ScreenAwakeControlling {
    private let id = UUID()
    private let coordinator: ScreenAwakeCoordinator
    init(coordinator: ScreenAwakeCoordinator = .shared) { self.coordinator = coordinator }
    func setAwake(_ awake: Bool) { coordinator.setAwake(awake, for: id) }
}
