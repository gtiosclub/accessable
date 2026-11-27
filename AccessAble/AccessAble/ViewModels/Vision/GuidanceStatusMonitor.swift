import Foundation
import UIKit

/// Owner: Computer Vision (1.1 / task T27). Keeps the display awake while camera guidance
/// runs, and holds the shared `GuidanceRecovery`, which announces when guidance stops or
/// comes back and asks for one restart when a session cannot recover on its own.
///
/// Used by the camera screen (`LiveSceneViewModel`). Kept separate from it because it is
/// about the one shared `ARSession`, which trips and Describe also run.
@MainActor
final class GuidanceStatusMonitor {
    private(set) var status: GuidanceStatus = .idle

    private let recovery: GuidanceRecovery
    private let announcements: any AnnouncementSink
    private var task: Task<Void, Never>?
    private var holdsRecovery = false

    init(recovery: GuidanceRecovery, announcements: any AnnouncementSink) {
        self.recovery = recovery
        self.announcements = announcements
    }

    /// Starts watching `provider`, replacing any previous subscription.
    func watch(_ provider: any GuidanceStatusProviding) {
        task?.cancel()
        if !holdsRecovery {
            recovery.hold(provider, announcements: announcements)
            holdsRecovery = true
        }
        status = provider.guidanceStatus
        setIdleTimerDisabled(status.keepsScreenAwake)
        task = Task { [weak self] in
            for await next in provider.guidanceStatuses() {
                guard let self else { return }
                self.apply(next)
            }
        }
    }

    /// Stops watching and lets the screen sleep again.
    func stop() {
        task?.cancel()
        task = nil
        if holdsRecovery {
            recovery.release()
            holdsRecovery = false
        }
        status = .idle
        setIdleTimerDisabled(false)
    }

    private func apply(_ next: GuidanceStatus) {
        guard next != status else { return }
        status = next
        setIdleTimerDisabled(next.keepsScreenAwake)
    }

    /// `isIdleTimerDisabled` is app-wide, so it is set from one place and always released:
    /// a screen that leaves it disabled drains the battery for the rest of the session.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}
