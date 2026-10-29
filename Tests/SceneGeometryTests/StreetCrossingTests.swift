import CoreGraphics
import Testing
@testable import SceneGeometry

@Suite("T37 — traffic lights, stop signs, crosswalks")
struct StreetCrossingTests {
    /// Every row has bright 8-cell bars every 16 cells in the lower half: zebra stripes.
    private func zebraGrid(width: Int = 96, height: Int = 128) -> LumaGrid {
        var values = [UInt8](repeating: 80, count: width * height)
        for y in (height / 2)..<height {
            for x in 0..<width where (x / 8) % 2 == 1 {
                values[y * width + x] = 220
            }
        }
        return LumaGrid(width: width, height: height, values: values)
    }

    private func sign(_ label: String, x: CGFloat = 0.45) -> Detection {
        Detection(
            label: label, confidence: 0.8, boundingBox: CGRect(x: x, y: 0.2, width: 0.1, height: 0.1),
            origin: .model, isHazard: false
        )
    }

    @Test("finds stripes, not plain road or tiles")
    func stripes() {
        let bars: [UInt8] = (0..<96).map { ($0 / 8) % 2 == 1 ? 220 : 70 }
        let road: [UInt8] = (0..<96).map { 90 + UInt8($0 % 5) }
        let tiles: [UInt8] = (0..<96).map { $0 % 12 == 0 ? 60 : 190 }
        #expect(isStriped(smoothed(bars)))
        #expect(!isStriped(smoothed(road)))
        #expect(!isStriped(smoothed(tiles)))
    }

    @Test("detects a zebra crossing in the lower part of the frame")
    func zebra() {
        #expect(detectCrosswalk(in: zebraGrid()) != nil)
        let blank = LumaGrid(width: 96, height: 128, values: [UInt8](repeating: 100, count: 96 * 128))
        #expect(detectCrosswalk(in: blank) == nil)
    }

    @Test("needs 3 of the last 5 frames")
    func confirmation() {
        var confirmer = CrosswalkConfirmer()
        let box = CGRect(x: 0, y: 0.5, width: 1, height: 0.45)
        #expect(confirmer.update(box) == nil)
        #expect(confirmer.update(nil) == nil)
        #expect(confirmer.update(box) == nil)
        #expect(confirmer.update(box) == box)
    }

    @Test("announces once after two frames, then waits")
    func announcesOnce() {
        var announcer = StreetSignalAnnouncer()
        #expect(announcer.announcements(for: [sign("stop sign")], at: 0).isEmpty)
        let events = announcer.announcements(for: [sign("stop sign")], at: 0.1)
        #expect(events.map(\.text) == ["Stop sign ahead."])
        #expect(events.first?.category == .landmark)
        #expect(announcer.announcements(for: [sign("stop sign")], at: 5).isEmpty)
        #expect(announcer.announcements(for: [sign("stop sign")], at: 21).count == 1)
    }

    @Test("ignores other labels and uses the box for the side without depth")
    func sides() {
        var announcer = StreetSignalAnnouncer()
        let frame = [sign("traffic light", x: 0.8), sign("chair")]
        _ = announcer.announcements(for: frame, at: 0)
        let events = announcer.announcements(for: frame, at: 0.1)
        #expect(events.map(\.text) == ["Traffic light on your right."])
    }

    @Test("never calls a crossing safe")
    func neverSafe() {
        var announcer = StreetSignalAnnouncer()
        let frame = [sign("crosswalk"), sign("traffic light"), sign("stop sign")]
        _ = announcer.announcements(for: frame, at: 0)
        let text = announcer.announcements(for: frame, at: 0.1).map(\.text).joined(separator: " ").lowercased()
        #expect(!text.isEmpty)
        #expect(!text.contains("safe"))
        #expect(!text.contains("cross now"))
    }
}
