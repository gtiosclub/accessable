import Foundation
import Observation

/// App-wide state for NFC info tags: the pins on every map, scanning, and volunteer edits.
/// Owned by `AppViewModel` and put in the environment, so every map shares one list.
@MainActor
@Observable
final class InfoTagsModel {
    private(set) var tags: [InfoTag] = []
    /// Volunteers can set up tags and edit descriptions; blind users hear them read aloud.
    /// Comes from the onboarding role until there are real accounts.
    var isVolunteer = false

    @ObservationIgnored private let repository: any InfoTagRepository
    @ObservationIgnored private let scanner: any NFCTagScanning
    @ObservationIgnored private let location: any LocationProvider
    @ObservationIgnored private let announcements: any AnnouncementSink
    @ObservationIgnored private let locationTimeout: Duration
    @ObservationIgnored private var hasLoaded = false

    init(
        repository: any InfoTagRepository,
        scanner: any NFCTagScanning,
        location: any LocationProvider,
        announcements: any AnnouncementSink,
        locationTimeout: Duration = .seconds(10)
    ) {
        self.locationTimeout = locationTimeout
        self.repository = repository
        self.scanner = scanner
        self.location = location
        self.announcements = announcements
    }

    var canScan: Bool { scanner.isAvailable }

    func tag(id: String) -> InfoTag? {
        tags.first { $0.id == id }
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        tags = (try? await repository.loadAll()) ?? []
    }

    // MARK: - Scanning

    enum ScanOutcome: Equatable {
        case opened(tagID: String)
        /// A volunteer set up a new tag; open it ready to write the description.
        case created(tagID: String)
        case failed(String)
        case cancelled
    }

    /// Reads a sticker and returns the tag to show.
    func scanTag() async -> ScanOutcome {
        await load()
        let result: NFCScanResult
        do {
            result = try await scanner.scan(.read)
        } catch {
            return error == .cancelled ? .cancelled : .failed(error.message)
        }
        guard tag(id: result.tagID) != nil else {
            return .failed(isVolunteer
                ? "This tag isn't on the map yet. Use “Set up new tag here” while standing next to it."
                : "This tag doesn't have a description yet.")
        }
        return .opened(tagID: result.tagID)
    }

    /// Volunteers: pins a sticker at where they are standing. Gets the location before the
    /// scan, so a sticker never gets an ID without a pin to go with it.
    func setUpTagHere() async -> ScanOutcome {
        await load()
        guard let here = await currentLocation(timeout: locationTimeout) else {
            return .failed("Couldn't find your location. Check that Location is on for AccessAble and try again outside.")
        }
        let result: NFCScanResult
        do {
            result = try await scanner.scan(.setUp)
        } catch {
            return error == .cancelled ? .cancelled : .failed(error.message)
        }
        if tag(id: result.tagID) != nil {
            // Already on the map; don't move its pin.
            return .opened(tagID: result.tagID)
        }
        let tag = InfoTag(id: result.tagID, coordinate: here)
        do {
            try await repository.save(tag)
        } catch {
            return .failed("The tag was scanned but couldn't be saved. Try again.")
        }
        tags.append(tag)
        return .created(tagID: tag.id)
    }

    // MARK: - Descriptions

    func saveDescription(_ text: String, for id: String) async -> Bool {
        guard var tag = tag(id: id) else { return false }
        tag.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        tag.updatedAt = .now
        do {
            try await repository.save(tag)
        } catch {
            return false
        }
        if let index = tags.firstIndex(where: { $0.id == id }) { tags[index] = tag }
        return true
    }

    func readAloud(_ tag: InfoTag) {
        let event = AnnouncementEvent(
            category: .landmark, priority: .high, text: tag.spokenText,
            // userInteraction: always spoken, and never dropped as a repeat when asked again
            source: .userInteraction
        )
        Task { await announcements.submit(event) }
    }

    // MARK: - Location

    /// The first reasonably accurate GPS fix, or nil after `timeout`.
    func currentLocation(timeout: Duration = .seconds(10)) async -> GeoCoordinate? {
        await location.requestAuthorization()
        let location = location
        return await withTaskGroup(of: GeoCoordinate?.self) { group in
            group.addTask {
                for await sample in location.locationSamples() where sample.horizontalAccuracy <= 50 {
                    return sample.coordinate
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
