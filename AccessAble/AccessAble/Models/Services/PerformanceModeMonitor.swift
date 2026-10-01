import Foundation

/// Resolves `PerformanceModeSetting` against Low Power Mode and thermal state and publishes the result.
/// Starting point for 3.3 — extend rather than replace so CV and Maps keep the same subscription API.
@MainActor
@Observable
final class PerformanceModeMonitor: PerformanceModeProviding {
    private(set) var mode: PerformanceMode = .normal
    var setting: PerformanceModeSetting = .automatic {
        didSet { refresh() }
    }

    @ObservationIgnored private nonisolated let broadcaster = Broadcaster<PerformanceMode>(replaysLatest: true)
    @ObservationIgnored private var observers: [Task<Void, Never>] = []

    init() {
        mode = resolvedMode()
        broadcaster.send(mode)
        observers = [
            NSNotification.Name.NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
        ].map { name in
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) {
                    self?.refresh()
                }
            }
        }
    }

    isolated deinit {
        observers.forEach { $0.cancel() }
    }

    nonisolated func modes() -> AsyncStream<PerformanceMode> {
        broadcaster.stream()
    }

    private func resolvedMode() -> PerformanceMode {
        let info = ProcessInfo.processInfo
        return setting.resolve(isLowPowerModeEnabled: info.isLowPowerModeEnabled, thermalState: info.thermalState)
    }

    private func refresh() {
        let resolved = resolvedMode()
        guard resolved != mode else { return }
        mode = resolved
        broadcaster.send(resolved)
    }
}
