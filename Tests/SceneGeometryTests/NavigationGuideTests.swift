import CoreGraphics
import Foundation
import Testing
import simd
@testable import SceneGeometry

@Suite("Navigation — take me to the chair")
struct NavigationGuideTests {
    /// A level heading at `origin` turned `yawDegrees` clockwise from -Z.
    private func heading(at origin: SIMD3<Float> = [0, 1.4, 0], yawDegrees: Float = 0) -> WalkingCorridor {
        let yaw = yawDegrees * .pi / 180
        return WalkingCorridor(origin: origin, forward: [sin(yaw), 0, -cos(yaw)], right: [cos(yaw), 0, sin(yaw)], width: 0.9, maxDistance: 4)
    }

    private func chair(at position: SIMD3<Float>) -> Detection {
        Detection(label: "chair", confidence: 0.9, boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
                  distance: 2, bearing: .ahead, origin: .geometric, isHazard: true, worldPosition: position)
    }

    @Test("the first frame says what is happening")
    func intro() {
        var guide = NavigationGuide(query: "the chair", at: 0)
        let (status, event) = guide.update(detections: [], text: [], heading: heading(), at: 0)
        #expect(status.phase == .scanning)
        #expect(event?.text == "Looking for the chair. Turn slowly all the way around.")
        #expect(event?.category == .maneuver && event?.source == .navigation)
    }

    @Test("a sighting while scanning starts guiding, with the direction to turn")
    func sightingStartsGuiding() {
        var guide = NavigationGuide(query: "chair", at: 0)
        _ = guide.update(detections: [], text: [], heading: heading(), at: 0)
        // Chair 3 m to the user's right while they face -Z.
        let (status, event) = guide.update(detections: [chair(at: [3, 0.5, 0])], text: [], heading: heading(), at: 2)
        #expect(status.phase == .guiding)
        #expect(status.bearing?.side == .right)
        #expect(abs((status.distance ?? 0) - 3) < 0.01)
        #expect(event?.text == "Turn right. Chair is 3 metres away.")
        #expect(event?.haptic == .turnRight)
    }

    @Test("after the sighting, the camera pose alone steers: turn to face it and it is straight ahead")
    func steersFromPose() {
        var guide = NavigationGuide(query: "chair", at: 0)
        _ = guide.update(detections: [chair(at: [3, 0.5, 0])], text: [], heading: heading(), at: 0)
        _ = guide.update(detections: [], text: [], heading: heading(), at: 0.1)
        // Turned 90° right, chair no longer detected.
        let (status, event) = guide.update(detections: [], text: [], heading: heading(yawDegrees: 90), at: 2)
        #expect(status.bearing?.side == .ahead)
        #expect(event?.text == "Chair straight ahead, 3 metres.")
        #expect(event?.haptic == .onRouteHeartbeat)
    }

    @Test("unchanged instructions repeat only every repeat interval")
    func cadence() {
        var guide = NavigationGuide(query: "chair", at: 0)
        _ = guide.update(detections: [chair(at: [0, 0.5, -3])], text: [], heading: heading(), at: 0)
        let counts = (1 ... 10).map { frame in
            guide.update(detections: [], text: [], heading: heading(), at: Double(frame) * 0.5).announcement == nil ? 0 : 1
        }
        // Spoken at 0 (sighting), then at 4 s and 8 s.
        #expect(counts == [0, 0, 0, 0, 0, 0, 0, 1, 0, 0])
    }

    @Test("arriving within a metre ends the request")
    func arrival() {
        var guide = NavigationGuide(query: "chair", at: 0)
        _ = guide.update(detections: [chair(at: [0, 0.5, -3])], text: [], heading: heading(), at: 0)
        let (status, event) = guide.update(detections: [], text: [], heading: heading(at: [0, 1.4, -2.2]), at: 3)
        #expect(status.phase == .arrived)
        #expect(event?.text == "You have arrived. Chair is right in front of you.")
        #expect(event?.haptic == .arrived)
        #expect(!guide.isActive)
        #expect(guide.update(detections: [], text: [], heading: heading(), at: 4).announcement == nil)
    }

    @Test("a full turn without a sighting gives up")
    func notFound() {
        var guide = NavigationGuide(query: "chair", at: 0)
        var givingUp: (status: NavigationStatus, announcement: AnnouncementEvent?)?
        var stepsTaken = 0
        for step in 0 ... 36 where givingUp == nil {
            let result = guide.update(detections: [], text: [], heading: heading(yawDegrees: Float(step) * 10), at: Double(step) * 0.2)
            stepsTaken = step
            if result.status.phase == .notFound { givingUp = result }
        }
        #expect(stepsTaken == 34)
        #expect(givingUp?.announcement?.text == "I couldn't find chair here.")
        #expect(!guide.isActive)
        #expect(guide.update(detections: [], text: [], heading: heading(), at: 10).announcement == nil)
    }

    @Test("scan progress accumulates across the wrap-around")
    func scanProgress() {
        var guide = NavigationGuide(query: "chair", at: 0)
        var status = guide.update(detections: [], text: [], heading: heading(yawDegrees: 170), at: 0).status
        status = guide.update(detections: [], text: [], heading: heading(yawDegrees: -170), at: 0.5).status
        #expect(abs(status.scannedDegrees - 20) < 0.5)
    }

    @Test("signs count: text containing the query places the target")
    func textTarget() {
        var guide = NavigationGuide(query: "room 210", at: 0)
        let sign = RecognizedText(string: "ROOM 210", confidence: 0.9, boundingBox: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.1), worldPosition: [-2, 1.6, -2])
        let (status, event) = guide.update(detections: [], text: [sign], heading: heading(), at: 0)
        #expect(status.phase == .guiding)
        #expect(status.bearing?.side == .left)
        #expect(event?.text == "Turn left. Room 210 is 3 metres away.")
    }

    @Test("everyday words find the model's labels", arguments: [
        ("someone", "person"), ("a seat", "bench"), ("the table", "dining table"), ("my bag", "suitcase"),
        ("chairs", "chair"), ("the nearest exit", "exit"), ("fire hydrant", "fire hydrant"),
    ])
    func synonyms(query: String, label: String) {
        #expect(NavigationGuide(query: query, at: 0).matches(label))
    }

    @Test("unrelated labels do not match")
    func noFalseMatches() {
        let guide = NavigationGuide(query: "chair", at: 0)
        #expect(!guide.matches("person"))
        #expect(!guide.matches("car"))
        #expect(!guide.matchesText("Exit"))
    }

    @Test("the position is the median of recent sightings, so one bad depth reading does not move it")
    func medianPosition() {
        var guide = NavigationGuide(query: "chair", at: 0)
        for (index, z) in [Float(-3), -3.1, -9, -2.9, -3].enumerated() {
            _ = guide.update(detections: [chair(at: [0, 0.5, z])], text: [], heading: heading(), at: Double(index) * 0.1)
        }
        #expect(abs((guide.estimatedPosition?.z ?? 0) + 3) < 0.01)
    }
}
