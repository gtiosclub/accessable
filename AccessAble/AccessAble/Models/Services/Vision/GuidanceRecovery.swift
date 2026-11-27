import Foundation
import Synchronization

/// Says when camera guidance stops or comes back, and asks for one restart when a session
/// cannot recover on its own (T27), for as long as anyone holds it.
///
/// One per app (`AppServices.guidanceRecovery`), shared by the trip and the camera screen: both
/// hold the one `ARSession`, and two watchers would restart it twice and say everything twice.
final class GuidanceRecovery: Sendable {
    private struct State {
        var holders = 0
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())

    /// Starts watching `provider` for the first holder; later holders join that watch.
    /// Each call needs one `release()`.
    func hold(_ provider: any GuidanceStatusProviding, announcements: any AnnouncementSink) {
        state.withLock { state in
            state.holders += 1
            guard state.holders == 1 else { return }
            state.task = Task { await Self.watch(provider, announcements: announcements) }
        }
    }

    /// Stops watching once the last holder lets go.
    func release() {
        let task = state.withLock { state -> Task<Void, Never>? in
            guard state.holders > 0 else { return nil }
            state.holders -= 1
            guard state.holders == 0 else { return nil }
            defer { state.task = nil }
            return state.task
        }
        task?.cancel()
    }

    private static func watch(_ provider: any GuidanceStatusProviding, announcements: any AnnouncementSink) async {
        var status = provider.guidanceStatus
        /// One automatic restart per failure. A session that fails again straight away is a
        /// device or permission problem, and retrying it in a loop only delays telling the user.
        var hasRetried = false
        for await next in provider.guidanceStatuses() {
            guard !Task.isCancelled else { return }
            let previous = status
            guard next != previous else { continue }
            status = next

            if let event = next.announcement(after: previous) { await announcements.submit(event) }
            if case .running = next { hasRetried = false }
            guard case .stopped = next, !hasRetried, !Task.isCancelled else { continue }
            hasRetried = true
            do {
                try await provider.restartGuidance()
            } catch {
                await announcements.submit(AnnouncementEvent(
                    category: .system,
                    priority: .critical,
                    text: "Camera guidance could not restart. \(error.localizedDescription)",
                    source: .system,
                    dedupKey: "guidance-restart-failed"
                ))
            }
        }
    }
}
