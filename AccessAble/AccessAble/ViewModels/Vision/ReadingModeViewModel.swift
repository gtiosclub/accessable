import Foundation
import Observation

/// Owner: Computer Vision (1.3 / task T29). A dedicated "read signs and text" mode: runs
/// the shared camera, speaks each new piece of text once as it's found, and lets the user
/// ask for the most recent reading again.
@MainActor
@Observable
final class ReadingModeViewModel {
    /// Text currently in view, most confident first — the same list "Describe my
    /// surroundings" draws from.
    private(set) var visibleText: [RecognizedText] = []
    /// The most recent new reading, kept after it scrolls out of view so "replay" still works.
    private(set) var lastReading: RecognizedText?
    private(set) var errorMessage: String?

    @ObservationIgnored private let services: AppServices
    /// Normalized strings already announced this session, so each sign is spoken once.
    @ObservationIgnored private var announcedKeys: Set<String> = []

    init(services: AppServices) {
        self.services = services
    }

    /// Holds the shared camera until the calling task is cancelled.
    func start() async {
        do {
            try await services.scene.start()
        } catch {
            errorMessage = "Reading mode needs the camera, which isn't available."
            return
        }
        for await observation in services.scene.observations() {
            visibleText = observation.recognizedText
            await announceNewText(in: observation.recognizedText)
        }
        await services.scene.stop()
    }

    /// Speaks the most recent reading again, even if it's no longer in view.
    func replayLastReading() async {
        guard let lastReading else { return }
        await services.announcements.submit(AnnouncementEvent(
            category: .landmark,
            priority: .normal,
            text: lastReading.string,
            source: .textRecognition,
            // Unique per press so the engine's short dedup window never swallows a replay.
            dedupKey: "text-replay-\(Date().timeIntervalSince1970)"
        ))
    }

    private func announceNewText(in texts: [RecognizedText]) async {
        for text in texts {
            let key = RecognizedTextMemory.key(for: text.string)
            guard !announcedKeys.contains(key) else { continue }
            announcedKeys.insert(key)
            lastReading = text
            await services.announcements.submit(AnnouncementEvent(
                category: .landmark,
                priority: .normal,
                text: text.string,
                source: .textRecognition,
                dedupKey: "text-\(key)"
            ))
        }
    }
}
