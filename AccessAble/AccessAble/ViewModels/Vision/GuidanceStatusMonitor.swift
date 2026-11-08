import Foundation
import UIKit

/// Owner: Computer Vision (1.1 / task T27). Keeps the display awake while camera guidance
/// runs, announces when guidance stops or comes back, and asks for one restart when a
/// session cannot recover on its own.
///
/// Used by the camera screen (`LiveSceneViewModel`). Kept separate from it because it is
/// about the one shared `ARSession`, which trips and Describe also run.
@MainActor
final class GuidanceStatusMonitor {
    private(set) var status: GuidanceStatus = .idle

    private let announcements: any AnnouncementSink
    private var task: Task<Void, Never>?
    /// One automatic restart per failure. A session that fails again straight away is a
    /// device or permission problem, and retrying it in a loop only delays telling the user.
    private var hasRetried = false

    init(announcements: any AnnouncementSink) {
        self.announcements = announcements
    }

    /// Starts watching `provider`, replacing any previous subscription.
    func watch(_ provider: any GuidanceStatusProviding) {
        task?.cancel()
        status = provider.guidanceStatus
        setIdleTimerDisabled(status.keepsScreenAwake)
        task = Task { [weak self] in
            for await next in provider.guidanceStatuses() {
                guard let self else { return }
                self.apply(next, from: provider)
            }
        }
    }

    /// Stops watching and lets the screen sleep again.
    func stop() {
        task?.cancel()
        task = nil
        status = .idle
        hasRetried = false
        setIdleTimerDisabled(false)
    }

    private func apply(_ next: GuidanceStatus, from provider: any GuidanceStatusProviding) {
        let previous = status
        guard next != previous else { return }
        status = next
        setIdleTimerDisabled(next.keepsScreenAwake)

        if let event = next.announcement(after: previous) {
            Task { [announcements] in await announcements.submit(event) }
        }
        if case .running = next { hasRetried = false }
        guard case .stopped = next, !hasRetried else { return }
        hasRetried = true
        Task { [weak self] in
            do {
                try await provider.restartGuidance()
            } catch {
                await self?.announceRestartFailure(error)
            }
        }
    }

    private func announceRestartFailure(_ error: Error) async {
        await announcements.submit(AnnouncementEvent(
            category: .system,
            priority: .critical,
            text: "Camera guidance could not restart. \(error.localizedDescription)",
            source: .system,
            dedupKey: "guidance-restart-failed"
        ))
    }

    /// `isIdleTimerDisabled` is app-wide, so it is set from one place and always released:
    /// a screen that leaves it disabled drains the battery for the rest of the session.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}
