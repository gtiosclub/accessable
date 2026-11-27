import Foundation

/// Hold time, repeat cooldown, and turn-away logic for point-to-scan announcements.
@MainActor
final class PointToScanSpeechPolicy {
    static let holdDuration: Duration = .milliseconds(300)
    static let repeatCooldown: TimeInterval = 10

    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date

    private var pendingID: String?
    private var holdTask: Task<Void, Never>?
    private var lastSpokenID: String?
    private var lastSpokenAt: Date?
    private var allowsRepeatForLastPlace = false
    private var didAnnounceScanStart = false

    init(clock: any Clock<Duration>, now: @escaping @Sendable () -> Date = { .now }) {
        self.clock = clock
        self.now = now
    }

    func resetScanSession() {
        holdTask?.cancel()
        holdTask = nil
        pendingID = nil
        allowsRepeatForLastPlace = false
        didAnnounceScanStart = false
    }

    func schedule(placeID: String?, announce: @escaping @MainActor (String) async -> Void) {
        holdTask?.cancel()
        pendingID = placeID
        guard let placeID else { return }
        holdTask = Task { @MainActor in
            try? await clock.sleep(for: Self.holdDuration)
            guard !Task.isCancelled, self.pendingID == placeID else { return }
            await self.considerAnnounce(placeID: placeID, announce: announce)
        }
    }

    func userTurnedAway() {
        holdTask?.cancel()
        holdTask = nil
        pendingID = nil
        if lastSpokenID != nil {
            allowsRepeatForLastPlace = true
        }
    }

    func scanStartCueIfNeeded(announce: @escaping @MainActor () async -> Void) async {
        guard !didAnnounceScanStart else { return }
        didAnnounceScanStart = true
        await announce()
    }

    private func considerAnnounce(
        placeID: String,
        announce: @escaping @MainActor (String) async -> Void
    ) async {
        if placeID == lastSpokenID, let lastSpokenAt {
            if now().timeIntervalSince(lastSpokenAt) < Self.repeatCooldown && !allowsRepeatForLastPlace { return }
        }
        allowsRepeatForLastPlace = false
        lastSpokenID = placeID
        self.lastSpokenAt = now()
        await announce(placeID)
    }
}