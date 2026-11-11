import CoreGraphics
import Foundation
import Testing
@testable import SceneGeometry

@Suite("Signs: what a plate says")
struct SignInterpreterTests {
    @Test("room plates read as a room with the rest of the plate as detail")
    func room() throws {
        let reading = try #require(SignInterpreter.interpret(["RM. 204A", "CHEMISTRY LAB"]))
        #expect(reading.category == .room)
        #expect(reading.spokenTitle == "Room 204A, Chemistry Lab")
    }

    @Test("exits, restrooms and elevators get plain names; a 'no exit' is not an exit")
    func names() {
        #expect(SignInterpreter.interpret(["EMERGENCY EXIT"])?.title == "Emergency exit")
        #expect(SignInterpreter.interpret(["WOMEN"])?.title == "Women's restroom")
        #expect(SignInterpreter.interpret(["ELEVATOR →"])?.directions == ["right"])
        #expect(SignInterpreter.interpret(["NO EXIT"]) == nil)
    }

    @Test("posters, prices and years are not signs")
    func notSigns() {
        #expect(SignInterpreter.interpret(["Join us for the spring career fair this Friday in the main hall"]) == nil)
        #expect(SignInterpreter.interpret(["COFFEE $3.50"]) == nil)
        #expect(SignInterpreter.interpret(["2024"]) == nil)
    }

    @Test("OCR's O for 0 is repaired inside a number, but a wing letter stays")
    func digitRepair() {
        #expect(SignInterpreter.repairingDigits("O266") == "0266")
        #expect(SignInterpreter.repairingDigits("2O4A") == "204A")
        #expect(SignInterpreter.repairingDigits("L204") == "L204")
        #expect(SignInterpreter.repairingDigits("ROOM") == "ROOM")
    }

    @Test("room 0266 is the same room as a plate reading 266, but not 267 or 266B against 266A")
    func sameRoom() {
        #expect(SignInterpreter.sameRoom("0266", "266"))
        #expect(SignInterpreter.sameRoom("0266", "O266"))
        #expect(!SignInterpreter.sameRoom("0266", "267"))
        #expect(!SignInterpreter.sameRoom("266A", "266B"))
        #expect(SignInterpreter.sameRoom("266", "266B"))
    }
}

@Suite("Take me to a room")
struct RoomNavigationTests {
    @Test("'Room 0266' finds the plate even when OCR drops the zero, and never a restroom")
    func roomMatching() {
        let guide = NavigationGuide(query: "Room 0266", at: 0)
        #expect(guide.matchesText("RM 266"))
        #expect(guide.matchesText("ROOM O266"))
        #expect(!guide.matchesText("RESTROOM"))
        #expect(!guide.matchesText("ROOM 0267"))
        #expect(!guide.matches("chair"))
    }

    @Test("non-room requests still match words")
    func wordMatching() {
        let guide = NavigationGuide(query: "the exit", at: 0)
        #expect(guide.matchesText("EXIT"))
    }
}

@Suite("Reading signs aloud")
struct SignAnnouncerTests {
    private func line(_ text: String, y: CGFloat, position: SIMD3<Float>? = nil) -> RecognizedText {
        RecognizedText(string: text, confidence: 0.9, boundingBox: CGRect(x: 0.4, y: y, width: 0.2, height: 0.05), worldPosition: position)
    }

    private let heading = WalkingCorridor(origin: .zero, forward: [0, 0, -1], right: [1, 0, 0], width: 1, maxDistance: 5)

    @Test("lines on one plate are one sign, spoken after two reads agree, with clock and distance")
    func speaksOnceAgreed() throws {
        var announcer = SignAnnouncer()
        // 3 m ahead, 1.7 m to the right: 30 degrees, 1 o'clock.
        let position = SIMD3<Float>(1.73, 0, -3)
        let first = announcer.announcements(for: [line("RM 204", y: 0.3, position: position), line("CHEMISTRY LAB", y: 0.36)], heading: heading, at: 0)
        #expect(first.isEmpty)
        let second = announcer.announcements(for: [line("RM 204", y: 0.3, position: position), line("CHEMISTRY LAB", y: 0.36)], heading: heading, at: 1)
        let event = try #require(second.first)
        #expect(event.text == "Room 204, Chemistry Lab. 1 o'clock, 3.5 metres.")
        #expect(event.source == .textRecognition)
    }

    @Test("the same frame's read seen again doesn't count as agreement, and a spoken sign waits to repeat")
    func agreementAndRepeat() {
        var announcer = SignAnnouncer()
        let read = [line("EXIT", y: 0.2)]
        #expect(announcer.announcements(for: read, heading: nil, at: 0).isEmpty)
        #expect(announcer.announcements(for: read, heading: nil, at: 0.5).isEmpty)
        #expect(announcer.announcements(for: [line("EXIT", y: 0.2)], heading: nil, at: 1).first?.text == "Exit.")
        #expect(announcer.announcements(for: [line("EXIT", y: 0.2)], heading: nil, at: 10).isEmpty)
    }

    @Test("Read mode reads text that isn't a sign; otherwise it is ignored")
    func plainText() {
        var signsOnly = SignAnnouncer()
        var reader = SignAnnouncer()
        reader.readsAllText = true
        for time in [0.0, 1.0] {
            _ = signsOnly.announcements(for: [line("Please wash your hands", y: 0.5)], heading: nil, at: time)
        }
        #expect(signsOnly.announcements(for: [line("Please wash your hands", y: 0.5)], heading: nil, at: 2).isEmpty)
        _ = reader.announcements(for: [line("Please wash your hands", y: 0.5)], heading: nil, at: 0)
        #expect(reader.announcements(for: [line("Please wash your hands", y: 0.5)], heading: nil, at: 1).first?.text == "Please wash your hands.")
    }

    @Test("clock directions")
    func clock() {
        #expect(SpokenPhrasing.clock(.ahead) == "12 o'clock")
        #expect(SpokenPhrasing.clock(RelativeBearing(degrees: 90)) == "3 o'clock")
        #expect(SpokenPhrasing.clock(RelativeBearing(degrees: -60)) == "10 o'clock")
    }
}

@Suite("Modes")
struct LiveModeTests {
    private func event(_ priority: AnnouncementPriority, _ source: AnnouncementSource) -> AnnouncementEvent {
        AnnouncementEvent(category: .hazard, priority: priority, text: "x", source: source)
    }

    @Test("Walk hears every warning; the other modes only Stop, plus their own output")
    func admits() {
        #expect(LiveMode.walk.admits(event(.high, .obstacleDetection)))
        for mode in [LiveMode.find, .read, .describe] {
            #expect(!mode.admits(event(.high, .obstacleDetection)))
            #expect(mode.admits(event(.critical, .obstacleDetection)))
            #expect(mode.admits(event(.normal, .textRecognition)))
            #expect(mode.admits(event(.normal, .navigation)))
        }
    }

    @Test("each mode runs only what it needs")
    func stages() {
        #expect(LiveMode.walk.watchesStreet && !LiveMode.walk.readsText && !LiveMode.walk.usesMesh)
        #expect(LiveMode.find.readsText && LiveMode.find.usesMesh)
        #expect(LiveMode.read.readsText && !LiveMode.read.usesMesh)
        // Describe reads text for its descriptions but only speaks when asked.
        #expect(LiveMode.describe.readsText && !LiveMode.describe.announcesSigns && !LiveMode.describe.watchesStreet)
        #expect(LiveMode.read.announcesSigns && LiveMode.find.announcesSigns && !LiveMode.walk.announcesSigns)
    }
}

@Suite("What the ground is made of")
struct WalkingSurfaceTests {
    /// A 10 × 10 map: `top` fills rows 0–4, `bottom` rows 5–9; `generation` tells reads apart.
    private func map(top: SurfaceKind, bottom: SurfaceKind, generation: Int = 1) -> SurfaceMap {
        SurfaceMap(width: 10, height: 10, kinds: Array(repeating: top, count: 50) + Array(repeating: bottom, count: 50), generation: generation)
    }

    @Test("model labels map onto the kinds that matter")
    func labels() {
        #expect(SurfaceKind(label: "floor (wood)") == .floor)
        #expect(SurfaceKind(label: "rug") == .floor)
        #expect(SurfaceKind(label: "road") == .road)
        #expect(SurfaceKind(label: "stairs") == .stairs)
        #expect(SurfaceKind(label: "sky (other)") == .outdoors)
        #expect(SurfaceKind(label: "laptop") == .other)
    }

    @Test("a drop with the same flat floor on both sides is a hole in depth, not an edge")
    func dismissesFlat() {
        let drop = [ElevationHazard(type: .dropOff, distance: 2, heightChange: 0)]
        #expect(checkingSurface(drop) { _ in .floor }.first?.type == .unknown)
        // Carpet the model calls road on one side and floor on the other is still level.
        #expect(checkingSurface(drop) { $0 < 2 ? .road : .road }.first?.type == .unknown)
    }

    @Test("stairs, a kerb onto the road, or ground out of view keep the warning")
    func keepsReal() {
        let drop = [ElevationHazard(type: .stepDown, distance: 2, heightChange: -0.15)]
        #expect(checkingSurface(drop) { $0 == 2 ? .stairs : .floor }.first?.type == .stepDown)
        #expect(checkingSurface(drop) { $0 < 2 ? .pavement : .grass }.first?.type == .stepDown)
        #expect(checkingSurface(drop) { $0 < 2 ? .floor : nil }.first?.type == .stepDown)
        let stepUp = [ElevationHazard(type: .stepUp, distance: 2, heightChange: 0.15)]
        #expect(checkingSurface(stepUp) { _ in .floor }.first?.type == .stepUp)
    }

    @Test("'Road ahead' needs outdoor evidence: grey carpet indoors reads as road")
    func roadNeedsOutdoors() {
        var indoors = SurfaceAnnouncer()
        for generation in 1 ... 3 {
            #expect(indoors.announcements(for: map(top: .ceiling, bottom: .road, generation: generation), at: Double(generation)).isEmpty)
        }
        var outdoors = SurfaceAnnouncer()
        _ = outdoors.announcements(for: map(top: .outdoors, bottom: .road, generation: 1), at: 0)
        #expect(outdoors.announcements(for: map(top: .outdoors, bottom: .road, generation: 2), at: 0.5).first?.text == "Road ahead.")
    }

    @Test("stairs ahead are announced after two separate reads, not twice from one")
    func stairsConfirmed() {
        var announcer = SurfaceAnnouncer()
        let first = map(top: .floor, bottom: .stairs, generation: 1)
        #expect(announcer.announcements(for: first, at: 0).isEmpty)
        #expect(announcer.announcements(for: first, at: 0.1).isEmpty)
        #expect(announcer.announcements(for: map(top: .floor, bottom: .stairs, generation: 2), at: 0.5).first?.text == "Stairs ahead.")
    }
}
