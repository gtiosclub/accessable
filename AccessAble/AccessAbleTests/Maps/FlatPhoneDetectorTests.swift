import Testing
@testable import AccessAble

struct FlatPhoneDetectorTests {
    @Test
    func entersFlatBelowThreshold() {
        var detector = FlatPhoneDetector()
        let tilted = detector.update(gravityZ: -0.5)
        #expect(!tilted)
        let flat = detector.update(gravityZ: -0.95)
        #expect(flat)
        #expect(detector.isFlat)
    }

    @Test
    func hysteresisPreventsFlicker() {
        var detector = FlatPhoneDetector()
        let entered = detector.update(gravityZ: -0.95)
        #expect(entered)
        let stillFlat = detector.update(gravityZ: -0.88)
        #expect(stillFlat)
        #expect(detector.isFlat)
        let left = detector.update(gravityZ: -0.8)
        #expect(!left)
        #expect(!detector.isFlat)
    }
}
