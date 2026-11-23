import Foundation
import Testing
@testable import SceneGeometry

/// A layout from a rule: `kind(along, lateral)`.
private func layout(outdoors: Bool = true, generation: Int = 1, _ kind: @escaping (Float, Float) -> SurfaceKind?) -> GroundLayout {
    GroundLayout(isOutdoors: outdoors, generation: generation, sample: kind)
}

/// A sidewalk with road starting `edge` metres to the right of the walking line.
private func sidewalk(roadRightFrom edge: Float) -> (Float, Float) -> SurfaceKind? {
    { _, lateral in lateral >= edge ? .road : .pavement }
}

@Suite("Outdoor — keeping to the sidewalk")
struct SidewalkGuideTests {
    @Test("a wide sidewalk is just a sidewalk")
    func wideSidewalk() {
        #expect(assessSidewalk(layout { _, _ in .pavement }) == .onSidewalk)
    }

    @Test("road starting within a metre of the walking line is close")
    func roadClose() {
        #expect(assessSidewalk(layout(sidewalk(roadRightFrom: 0.75))) == .roadBeside(.right, edge: 0.75))
    }

    @Test("road further off to the side is not worth a word")
    func roadFar() {
        #expect(assessSidewalk(layout(sidewalk(roadRightFrom: 1.25))) == .onSidewalk)
    }

    @Test("road underfoot, sidewalk to the left")
    func inRoad() {
        let situation = assessSidewalk(layout { _, lateral in lateral < -0.75 ? .pavement : .road })
        #expect(situation == .inRoad(sidewalkSide: .left))
    }

    @Test("the sidewalk ending straight ahead is a curb, with how far")
    func curbAhead() {
        let situation = assessSidewalk(layout { along, _ in along >= 2.5 ? .road : .pavement })
        #expect(situation == .curbAhead(distance: 2.5))
    }

    @Test("indoors nothing is said, whatever the model calls the carpet")
    func indoors() {
        #expect(assessSidewalk(layout(outdoors: false) { _, _ in .road }) == .unknown)
    }

    @Test("out of view or unlabelled ground decides nothing")
    func unseen() {
        #expect(assessSidewalk(layout { _, _ in nil }) == .unknown)
        #expect(assessSidewalk(layout { _, _ in .grass }) == .unknown)
    }

    @Test("a warning needs two segmentations, then holds back its repeat")
    func confirmsAndRepeats() {
        var guide = SidewalkGuide()
        let close = sidewalk(roadRightFrom: 0.75)
        #expect(guide.announcements(for: layout(generation: 1, close), at: 0).isEmpty)
        // The same segmentation read again on the next frame is not a second opinion.
        #expect(guide.announcements(for: layout(generation: 1, close), at: 0.1).isEmpty)
        let spoken = guide.announcements(for: layout(generation: 2, close), at: 0.4)
        #expect(spoken.map(\.text) == ["Road close on your right. Keep left."])
        #expect(spoken.first?.haptic == .turnLeft)
        #expect(guide.announcements(for: layout(generation: 3, close), at: 5).isEmpty)
        #expect(guide.announcements(for: layout(generation: 4, close), at: 16).count == 1)
    }

    @Test("a different situation starts its confirmation over")
    func switchingResets() {
        var guide = SidewalkGuide()
        _ = guide.announcements(for: layout(generation: 1, sidewalk(roadRightFrom: 0.75)), at: 0)
        let road = layout(generation: 2) { _, lateral in lateral < -0.75 ? .pavement : .road }
        #expect(guide.announcements(for: road, at: 0.4).isEmpty)
        let road2 = layout(generation: 3) { _, lateral in lateral < -0.75 ? .pavement : .road }
        #expect(guide.announcements(for: road2, at: 0.8).map(\.text) == ["You may be in the road. Sidewalk on your left."])
    }

    @Test("crossing at a crosswalk, being in the road is not news")
    func crossing() {
        var guide = SidewalkGuide()
        let road = { (generation: Int) in layout(generation: generation) { _, lateral in lateral < -0.75 ? .pavement : .road } }
        _ = guide.announcements(for: road(1), isCrossing: true, at: 0)
        #expect(guide.announcements(for: road(2), isCrossing: true, at: 0.4).isEmpty)
        #expect(guide.current == .inRoad(sidewalkSide: .left))
        #expect(guide.announcements(for: road(3), isCrossing: false, at: 0.8).count == 1)
    }

    @Test("ADE20K's names fold into the ground classes")
    func adeLabels() {
        #expect(SurfaceKind(label: "sidewalk") == .pavement)
        #expect(SurfaceKind(label: "path") == .pavement)
        #expect(SurfaceKind(label: "stairway") == .stairs)
        #expect(SurfaceKind(label: "earth") == .rough)
        #expect(SurfaceKind(label: "skyscraper") == .outdoors)
        #expect(SurfaceKind(label: "floor (wood)") == .floor)
    }
}
