import Foundation
 
actor AnnouncementEngine: AnnouncementEngineProtocol {
    private nonisolated let delivered = Broadcaster<AnnouncementEvent>()
    private let speech: SpeechOutput
    private let haptics: any HapticRendering
 
    private var profile: GuidanceProfile = .default
    private var isPaused = false
    private var queue: [AnnouncementEvent] = []
    private var isDraining = false
    private var current: AnnouncementEvent?
    private var last: AnnouncementEvent?
    private var recentKeys: [String: Date] = [:]
    /// How many times each announcement has already been spoken in its current episode, for
    /// the profile's `autoRepeat` limit (T50). Cleared per key once it goes quiet.
    private var repeatCounts: [String: (count: Int, lastSpoken: Date)] = [:]
    /// When the last thing was spoken, for the gap between announcements (T50).
    private var lastSpokenAt: Date?
 
    private let dedupWindow: TimeInterval = 4
    private let defaultStaleness: TimeInterval = 5
    /// Shortest gap between two spoken announcements, across every producer. The camera's
    /// `SpeechBudget` paces its own announcers, but nothing paced the camera against the
    /// maps side, so a turn instruction and an obstacle warning could run together with no
    /// breath between them (T50).
    ///
    /// An event held by this gap is delayed rather than dropped: losing a turn cue because
    /// an obstacle was announced a moment earlier is worse than hearing it a second late,
    /// and `isStale` already discards anything that waited too long.
    private let minimumGap: TimeInterval = 2.5
    /// A key unheard for this long starts a new episode, so its repeat count resets.
    private let repeatEpisodeGap: TimeInterval = 20
 
    init(speech: SpeechOutput, haptics: any HapticRendering) {
        self.speech = speech
        self.haptics = haptics
    }
 
    // AnnouncementEngineProtocol

    func submit(_ event: AnnouncementEvent) async {
        guard !isPaused, profile.allows(event), !event.isExpired(), !isDuplicate(event),
              !hasRepeatedEnough(event)
        else { return }
        await enqueue(event)
    }
 
    nonisolated func deliveredEvents() -> AsyncStream<AnnouncementEvent> {
        delivered.stream(bufferingPolicy: .bufferingNewest(8))
    }

    // Magic Tap  or repeat that would skip dedup and profile filter
    func repeatLast() async {
        guard let last else { return }
        await enqueue(AnnouncementEvent(
            category: last.category, priority: .high, text: last.text,
            distance: last.distance, bearing: last.bearing, source: last.source
        ))
    }
 
    func pause() async {
        isPaused = true
        queue.removeAll()
        await speech.stop()
        await haptics.stop()
    }
 
    func resume() async { isPaused = false }
 
    func updateProfile(_ profile: GuidanceProfile) async { self.profile = profile }
 
    // Queue
 
    private func enqueue(_ event: AnnouncementEvent) async {
        if event.priority == .critical {
            queue.removeAll { $0.priority <= .normal }
        }
        // Ordering is by urgency first. Among events of equal urgency, a topic the user asked
        // to hear first goes ahead of one they did not — which is all a preference may do.
        let preferred = profile.prefersFirst(event)
        let index = queue.firstIndex { queued in
            queued.priority < event.priority
                || (queued.priority == event.priority && preferred && !profile.prefersFirst(queued))
        } ?? queue.endIndex
        queue.insert(event, at: index)
 
        if event.priority == .critical, let current, current.priority < .critical {
            await speech.stop() // drain() moves on to the critical event right away
        }
        if !isDraining {
            isDraining = true
            Task { await drain() } // don't make the producer wait for speech to finish
        }
    }
 
    private func drain() async {
        while let event = nextFreshEvent() {
            await waitForGap(before: event)
            // Waiting yields the actor, so a more urgent event may have arrived meanwhile.
            // Put this one back and take the queue's view again rather than speaking it now.
            if let queued = queue.first, queued.priority > event.priority {
                queue.insert(event, at: 0)
                continue
            }
            current = event
            last = event
            delivered.send(event)
            let buzzes = event.haptic != nil && profile.channels.contains(.haptics)
            if let haptic = event.haptic, buzzes {
                await haptics.play(haptic, intensity: profile.hapticIntensity * distanceScale(for: event))
            } else if event.haptic == nil, event.category == .hazard {
                // "Path clear": a warning buzz still looping would say the opposite.
                await haptics.stop()
            }
            if profile.channels.contains(.speech), !(event.hapticOnly && buzzes) {
                await speech.speak(event.text, rate: profile.speechRate, interrupting: event.priority == .critical)
                lastSpokenAt = .now
                recordSpoken(event)
            }
            current = nil
        }
        isDraining = false
    }

    /// Ramps obstacle haptics from 45% strength at 5 m to full strength at 0.5 m.
    /// If distance is unavailable, preserve the user's configured intensity.
    private func distanceScale(for event: AnnouncementEvent) -> Float {
        guard event.haptic == .obstacleNear || event.haptic == .obstacleNearer || event.haptic == .stop,
              let distance = event.distance, distance.isFinite else { return 1 }
        let clampedDistance = min(max(distance, 0.5), 5.0)
        let proximity = (5.0 - clampedDistance) / 4.5
        return Float(0.45 + proximity * 0.55)
    }
 
    /// Holds a non-urgent announcement back until `minimumGap` has passed since the last
    /// one. Critical events never wait.
    private func waitForGap(before event: AnnouncementEvent) async {
        guard event.priority != .critical, profile.channels.contains(.speech),
              !event.hapticOnly, let lastSpokenAt
        else { return }
        let remaining = minimumGap - Date.now.timeIntervalSince(lastSpokenAt)
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
    }

    /// Whether this announcement has already repeated as often as the profile allows.
    private func hasRepeatedEnough(_ event: AnnouncementEvent, now: Date = .now) -> Bool {
        guard let limit = profile.repeatLimit(for: event) else { return false }
        let key = event.dedupKey ?? event.text
        guard let seen = repeatCounts[key], now.timeIntervalSince(seen.lastSpoken) < repeatEpisodeGap
        else { return false }
        return seen.count > limit
    }

    private func recordSpoken(_ event: AnnouncementEvent, now: Date = .now) {
        let key = event.dedupKey ?? event.text
        let previous = repeatCounts[key]
        let continuing = previous.map { now.timeIntervalSince($0.lastSpoken) < repeatEpisodeGap } ?? false
        repeatCounts[key] = (count: continuing ? (previous?.count ?? 0) + 1 : 1, lastSpoken: now)
        repeatCounts = repeatCounts.filter { now.timeIntervalSince($0.value.lastSpoken) < repeatEpisodeGap }
    }

    private func nextFreshEvent() -> AnnouncementEvent? {
        while !queue.isEmpty {
            let event = queue.removeFirst()
            if !isStale(event) { return event }
        }
        return nil
    }
 
    private func isStale(_ event: AnnouncementEvent, now: Date = .now) -> Bool {
        if event.isExpired(at: now) { return true }
        return event.expiresAt == nil
            && event.priority <= .normal
            && now.timeIntervalSince(event.createdAt) > defaultStaleness
    }
 
    private func isDuplicate(_ event: AnnouncementEvent, now: Date = .now) -> Bool {
        // Asking the same thing twice ("where am I?") should get an answer both times
        if event.source == .userInteraction { return false }
        recentKeys = recentKeys.filter { now.timeIntervalSince($0.value) < dedupWindow }
        let key = event.dedupKey ?? event.text
        if recentKeys[key] != nil { return true }
        recentKeys[key] = now
        return false
    }
}
