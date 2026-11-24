import Foundation
import Testing
@testable import AccessAble

private let here = GeoCoordinate(latitude: 33.7756, longitude: -84.3963)

/// Always at `here`, accurately.
private struct FixedLocationProvider: LocationProvider {
    var accuracy: Double = 5

    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in
            continuation.yield(LocationSample(coordinate: here, horizontalAccuracy: accuracy, timestamp: .now))
        }
    }

    func headingSamples() -> AsyncStream<HeadingSample> { AsyncStream { $0.finish() } }
    func authorizationStates() -> AsyncStream<LocationAuthorization> { AsyncStream { $0.finish() } }
    func requestAuthorization() async {}
}

/// Returns a canned scan result instead of opening the NFC sheet.
@MainActor
private final class FakeScanner: NFCTagScanning {
    var isAvailable = true
    var result: Result<NFCScanResult, NFCScanError>
    private(set) var purposes: [NFCScanPurpose] = []

    init(_ result: Result<NFCScanResult, NFCScanError>) {
        self.result = result
    }

    func scan(_ purpose: NFCScanPurpose) async throws(NFCScanError) -> NFCScanResult {
        purposes.append(purpose)
        return try result.get()
    }
}

private actor RecordingSink: AnnouncementSink {
    private(set) var events: [AnnouncementEvent] = []
    func submit(_ event: AnnouncementEvent) async { events.append(event) }
}

@MainActor
private func makeModel(
    tags: [InfoTag] = [],
    scan: Result<NFCScanResult, NFCScanError>,
    location: any LocationProvider = FixedLocationProvider(),
    sink: RecordingSink = RecordingSink()
) -> (InfoTagsModel, FakeScanner) {
    let scanner = FakeScanner(scan)
    let model = InfoTagsModel(
        repository: InMemoryInfoTagRepository(tags: tags),
        scanner: scanner,
        location: location,
        announcements: sink,
        locationTimeout: .milliseconds(200)
    )
    return (model, scanner)
}

struct InfoTagLinkTests {
    @Test
    func roundTripsTheTagID() {
        let id = InfoTagLink.newID()
        #expect(InfoTagLink.tagID(from: InfoTagLink.url(for: id)) == id)
    }

    @Test
    func ignoresOtherURLs() throws {
        #expect(InfoTagLink.tagID(from: try #require(URL(string: "https://example.com/tag/abc"))) == nil)
        #expect(InfoTagLink.tagID(from: try #require(URL(string: "accessable://route/abc"))) == nil)
        #expect(InfoTagLink.tagID(from: try #require(URL(string: "accessable://tag"))) == nil)
    }
}

struct LocalInfoTagRepositoryTests {
    @Test
    func savedTagsSurviveANewRepository() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "InfoTags-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }

        var tag = InfoTag(id: "a", coordinate: here, text: "Bench to the left")
        try await LocalInfoTagRepository(fileURL: file).save(tag)
        tag.text = "Bench to the left, fountain ahead"
        try await LocalInfoTagRepository(fileURL: file).save(tag)

        let loaded = try await LocalInfoTagRepository(fileURL: file).loadAll()
        #expect(loaded == [tag])
    }
}

@MainActor
struct InfoTagsModelTests {
    @Test
    func scanningAKnownTagOpensIt() async {
        let (model, _) = makeModel(tags: [InfoTag(id: "a", coordinate: here)], scan: .success(.found(tagID: "a")))
        #expect(await model.scanTag() == .opened(tagID: "a"))
    }

    @Test
    func scanningAnUnknownTagExplainsWhy() async {
        let (model, _) = makeModel(scan: .success(.found(tagID: "missing")))
        guard case .failed = await model.scanTag() else {
            Issue.record("expected a failure message")
            return
        }
    }

    @Test
    func cancellingIsQuiet() async {
        let (model, _) = makeModel(scan: .failure(.cancelled))
        #expect(await model.scanTag() == .cancelled)
    }

    @Test
    func settingUpAPinsTheTagWhereTheVolunteerIs() async {
        let (model, scanner) = makeModel(scan: .success(.created(tagID: "new")))
        model.isVolunteer = true

        #expect(await model.setUpTagHere() == .created(tagID: "new"))
        #expect(scanner.purposes == [.setUp])
        #expect(model.tag(id: "new")?.coordinate == here)
    }

    @Test
    func settingUpAnExistingTagDoesNotMoveIt() async {
        let elsewhere = GeoCoordinate(latitude: 33.78, longitude: -84.40)
        let (model, _) = makeModel(tags: [InfoTag(id: "a", coordinate: elsewhere)], scan: .success(.found(tagID: "a")))

        #expect(await model.setUpTagHere() == .opened(tagID: "a"))
        #expect(model.tag(id: "a")?.coordinate == elsewhere)
    }

    @Test
    func settingUpWithoutALocationNeverWritesTheSticker() async {
        let (model, scanner) = makeModel(
            scan: .success(.created(tagID: "new")),
            location: FixedLocationProvider(accuracy: 500)
        )
        guard case .failed = await model.setUpTagHere() else {
            Issue.record("expected a failure message")
            return
        }
        #expect(scanner.purposes.isEmpty)
        #expect(model.tags.isEmpty)
    }

    @Test
    func anyVolunteerCanUpdateTheDescription() async {
        let (model, _) = makeModel(tags: [InfoTag(id: "a", coordinate: here)], scan: .failure(.cancelled))
        await model.load()

        #expect(await model.saveDescription("  Crosswalk ahead, button on the right pole  ", for: "a"))
        #expect(model.tag(id: "a")?.text == "Crosswalk ahead, button on the right pole")
    }

    @Test
    func readsTheDescriptionAloud() async throws {
        let sink = RecordingSink()
        let tag = InfoTag(id: "a", coordinate: here, text: "Stairs down to the left")
        let (model, _) = makeModel(tags: [tag], scan: .failure(.cancelled), sink: sink)

        model.readAloud(tag)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await sink.events.map(\.text) == ["Stairs down to the left"])
    }
}
