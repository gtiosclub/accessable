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
        #expect(!LiveMode.describe.readsText && !LiveMode.describe.watchesStreet)
    }
}
