import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import AccessAble

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// One OCR read of a two-line plate; each read gives its lines new IDs.
private func plateRead(_ lines: [String] = ["JOHN LEWIS", "STUDENT CENTER"], confidence: Float = 0.9) -> [RecognizedText] {
    lines.enumerated().map { index, line in
        RecognizedText(string: line, confidence: confidence,
                       boundingBox: CGRect(x: 0.3, y: 0.30 + 0.06 * Double(index), width: 0.4, height: 0.05))
    }
}

struct SignSightingsTests {
    @Test
    func aPlateIsSentOnceTwoReadsAgree() {
        var signs = SignSightings()

        #expect(signs.sightings(in: plateRead(), at: start).isEmpty)
        let sightings = signs.sightings(in: plateRead(), at: start + 1)

        #expect(sightings.count == 1)
        #expect(sightings.first?.kind == .signText)
        #expect(sightings.first?.text == "JOHN LEWIS STUDENT CENTER")
        #expect(sightings.first?.confidence == 0.9)
        #expect(sightings.first?.wasAnnounced == false)
    }

    // frames between reads carry the same read again, which is no second opinion
    @Test
    func oneReadSeenOnManyFramesIsNotAgreement() {
        var signs = SignSightings()
        let read = plateRead()

        for second in 0..<5 {
            #expect(signs.sightings(in: read, at: start + Double(second)).isEmpty)
        }
    }

    @Test
    func readsTooFarApartStartOver() {
        var signs = SignSightings()

        _ = signs.sightings(in: plateRead(), at: start)
        #expect(signs.sightings(in: plateRead(), at: start + 6).isEmpty)
        #expect(signs.sightings(in: plateRead(), at: start + 7).count == 1)
    }

    @Test
    func aPlateInViewIsSentAgainOnlyAfterAWhile() {
        var signs = SignSightings()
        var sent = 0

        for second in 0...31 {
            sent += signs.sightings(in: plateRead(), at: start + Double(second)).count
        }

        // at 1 s, then at 31 s
        #expect(sent == 2)
    }

    @Test
    func anEntranceSignIsAnEntrance() {
        var signs = SignSightings()

        _ = signs.sightings(in: plateRead(["MAIN ENTRANCE"]), at: start)
        let sightings = signs.sightings(in: plateRead(["MAIN ENTRANCE"]), at: start + 1)

        #expect(sightings.map(\.kind) == [.entrance])
    }

    @Test(arguments: ["DO NOT ENTER", "NO ENTRY"])
    func aSignKeepingPeopleOutIsNoEntrance(_ text: String) {
        var signs = SignSightings()

        _ = signs.sightings(in: plateRead([text]), at: start)
        let sightings = signs.sightings(in: plateRead([text]), at: start + 1)

        #expect(sightings.map(\.kind) == [.signText])
    }

    @Test
    func scrapsOfTextAreIgnored() {
        var signs = SignSightings()

        _ = signs.sightings(in: plateRead(["A1"]), at: start)
        #expect(signs.sightings(in: plateRead(["A1"]), at: start + 1).isEmpty)
    }

    @Test
    func theCameraSayingItIsPassedOn() {
        var signs = SignSightings()

        _ = signs.sightings(in: plateRead(), at: start, isAnnounced: { _ in true })
        let sightings = signs.sightings(in: plateRead(), at: start + 1, isAnnounced: { _ in true })

        #expect(sightings.first?.wasAnnounced == true)
    }

    // the plate's lines joined must still name the building for the matcher
    @Test
    func aPlateReadAsTwoLinesMatchesTheBuilding() {
        var signs = SignSightings()

        _ = signs.sightings(in: plateRead(), at: start)
        let text = try? #require(signs.sightings(in: plateRead(), at: start + 1).first?.text)

        #expect(LandmarkMatcher.matches(LandmarkMatcher.tokens(text ?? ""), name: "John Lewis Student Center"))
    }
}

/// A camera whose observations the test sends.
private final class ScriptedScene: SceneObservationProviding {
    private let broadcaster = Broadcaster<SceneObservation>()

    func observations() -> AsyncStream<SceneObservation> { broadcaster.stream(bufferingPolicy: .unbounded) }
    func start() async throws {}
    func stop() async {}

    func send(_ texts: [RecognizedText], at time: Date) {
        broadcaster.send(SceneObservation(timestamp: time, recognizedText: texts))
    }
}

/// Records each switch of the camera's text reading.
private final class ReadingSwitch: Sendable {
    private let switches = Mutex<[Bool]>([])
    var history: [Bool] { switches.withLock { $0 } }
    func set(_ reads: Bool) { switches.withLock { $0.append(reads) } }
}

@Suite(.timeLimit(.minutes(1)))
struct CameraLandmarkProviderTests {
    @Test
    func signsTheCameraReadsReachTheTrip() async {
        let scene = ScriptedScene()
        let provider = CameraLandmarkProvider(scene: scene, setReadsText: { _ in })
        let sightings = provider.landmarkObservations()

        scene.send(plateRead(), at: start)
        scene.send(plateRead(), at: start + 1)

        var received: LandmarkObservation?
        for await sighting in sightings {
            received = sighting
            break
        }
        #expect(received?.text == "JOHN LEWIS STUDENT CENTER")
    }

    @Test
    func readingIsOnWhileAnyTripListens() async {
        let scene = ScriptedScene()
        let reading = ReadingSwitch()
        let provider = CameraLandmarkProvider(scene: scene, setReadsText: reading.set)

        let first = Task { for await _ in provider.landmarkObservations() {} }
        await waitUntil { reading.history == [true] }
        // a restarted trip listens before the old one has let go
        let listening = Mutex(false)
        let second = Task {
            let sightings = provider.landmarkObservations()
            listening.withLock { $0 = true }
            for await _ in sightings {}
        }
        await waitUntil { listening.withLock { $0 } }
        first.cancel()
        await first.value
        #expect(reading.history == [true])

        second.cancel()
        await second.value
        #expect(reading.history == [true, false])
    }
}

private func waitUntil(_ condition: () -> Bool) async {
    while !condition() { await Task.yield() }
}
