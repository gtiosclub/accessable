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
 
    private let dedupWindow: TimeInterval = 4
    private let defaultStaleness: TimeInterval = 5
 
    init(speech: SpeechOutput, haptics: any HapticRendering) {
        self.speech = speech
        self.haptics = haptics
    }
 
    // AnnouncementEngineProtocol

    func submit(_ event: AnnouncementEvent) async {
        guard !isPaused, profile.allows(event), !event.isExpired(), !isDuplicate(event) else { return }
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
            bearing: last.bearing, source: last.source
        ))
    }
 
    func pause() async {
        isPaused = true
        queue.removeAll()
        await speech.stop()
    }
 
    func resume() async { isPaused = false }
 
    func updateProfile(_ profile: GuidanceProfile) async { self.profile = profile }
 
    // Queue
 
    private func enqueue(_ event: AnnouncementEvent) async {
        if event.priority == .critical {
            queue.removeAll { $0.priority <= .normal }
        }
        let index = queue.firstIndex { $0.priority < event.priority } ?? queue.endIndex
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
            current = event
            last = event
            delivered.send(event)
            if let haptic = event.haptic, profile.channels.contains(.haptics) {
                await haptics.play(haptic, intensity: profile.hapticIntensity)
            }
            if profile.channels.contains(.speech) {
                await speech.speak(event.text, rate: profile.speechRate, interrupting: event.priority == .critical)
            }
            current = nil
        }
        isDraining = false
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
