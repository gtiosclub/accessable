import Foundation

/// When point-to-scan names the place it points at: after the target holds for a moment, and the same place
/// again only once the user turned away and back, or after a long while still pointing at it.
@MainActor
final class PointToScanSpeechPolicy {
    /// A target must hold this long, so a fast sweep doesn't produce a burst.
    static let holdDuration: Duration = .milliseconds(300)
    /// Seconds. The place last named is named again, while still pointed at, only after this long.
    static let repeatInterval: TimeInterval = 30
    /// Seconds the user must stay turned away from the place last named before it may be named again on return.
    static let turnAwayDuration: TimeInterval = 1

    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date

    private var pendingID: String?
    /// Runs the hold for `pendingID`; tests await it.
    private(set) var holdTask: Task<Void, Never>?
    private var holdElapsed = false
    private(set) var lastSpokenID: String?
    private var lastSpokenAt: Date?
    private var turnedAwaySince: Date?
    private var mayRepeatLastSpoken = false

    init(clock: any Clock<Duration>, now: @escaping @Sendable () -> Date) {
        self.clock = clock
        self.now = now
    }

    isolated deinit {
        holdTask?.cancel()
    }

    /// Forgets everything: a new scan names what it points at.
    func resetScanSession() {
        holdTask?.cancel()
        holdTask = nil
        pendingID = nil
        holdElapsed = false
        lastSpokenID = nil
        lastSpokenAt = nil
        turnedAwaySince = nil
        mayRepeatLastSpoken = false
    }

    /// Call on every heading or location update with the place pointed at (nil for none) and whether the user
    /// is turned well away from the place last named. `speak` runs when that place should be named.
    func update(target: String?, turnedAwayFromLastSpoken: Bool, speak: @escaping @MainActor (String) -> Void) {
        trackTurnAway(turnedAwayFromLastSpoken)
        guard target == pendingID else {
            startHold(for: target, speak: speak)
            return
        }
        if let target, holdElapsed, isDue(target) {
            say(target, speak: speak)
        }
    }

    private func startHold(for target: String?, speak: @escaping @MainActor (String) -> Void) {
        holdTask?.cancel()
        holdTask = nil
        pendingID = target
        holdElapsed = false
        guard let target else { return }
        holdTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: Self.holdDuration)
            } catch {
                return
            }
            self?.finishHold(for: target, speak: speak)
        }
    }

    private func finishHold(for target: String, speak: @MainActor (String) -> Void) {
        guard pendingID == target, !holdElapsed else { return }
        holdElapsed = true
        if isDue(target) { say(target, speak: speak) }
    }

    private func trackTurnAway(_ turnedAway: Bool) {
        guard lastSpokenID != nil, turnedAway else {
            turnedAwaySince = nil
            return
        }
        let since = turnedAwaySince ?? now()
        turnedAwaySince = since
        if now().timeIntervalSince(since) >= Self.turnAwayDuration { mayRepeatLastSpoken = true }
    }

    private func isDue(_ placeID: String) -> Bool {
        guard placeID == lastSpokenID, let lastSpokenAt else { return true }
        return mayRepeatLastSpoken || now().timeIntervalSince(lastSpokenAt) >= Self.repeatInterval
    }

    private func say(_ placeID: String, speak: @MainActor (String) -> Void) {
        lastSpokenID = placeID
        lastSpokenAt = now()
        turnedAwaySince = nil
        mayRepeatLastSpoken = false
        speak(placeID)
    }
}
