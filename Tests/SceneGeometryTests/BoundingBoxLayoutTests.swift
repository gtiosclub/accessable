import CoreGraphics
import Foundation
import Testing
@testable import SceneGeometry

@Suite("Overlay box layout")
struct BoundingBoxLayoutTests {
    @Test("a full-frame box covers at least the whole view")
    func fullFrameCoversView() {
        let rect = aspectFillRect(
            normalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 3.0 / 4.0,
            viewSize: CGSize(width: 390, height: 844)
        )

        // Aspect-fill crops, so the box may overflow — but it must never leave a gap.
        #expect(rect.minX <= 0.001)
        #expect(rect.minY <= 0.001)
        #expect(rect.maxX >= 390 - 0.001)
        #expect(rect.maxY >= 844 - 0.001)
    }

    @Test("the centre of the image maps to the centre of the view")
    func centreMapsToCentre() {
        let viewSize = CGSize(width: 390, height: 844)
        let rect = aspectFillRect(
            normalizedBox: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1),
            imageAspectRatio: 3.0 / 4.0,
            viewSize: viewSize
        )

        #expect(abs(rect.midX - viewSize.width / 2) < 0.001)
        #expect(abs(rect.midY - viewSize.height / 2) < 0.001)
    }

    @Test("a portrait image in a portrait view overflows horizontally, not vertically")
    func tallViewCropsWidth() {
        // 3:4 image in a 390x844 view: matching the width would leave the height short,
        // so the width is what overflows.
        let rect = aspectFillRect(
            normalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 3.0 / 4.0,
            viewSize: CGSize(width: 390, height: 844)
        )

        #expect(rect.width > 390)
        #expect(abs(rect.height - 844) < 0.001)
        #expect(rect.minX < 0)
    }

    @Test("a wide image in a square view overflows horizontally")
    func wideImageInSquareView() {
        let rect = aspectFillRect(
            normalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 16.0 / 9.0,
            viewSize: CGSize(width: 400, height: 400)
        )

        #expect(abs(rect.height - 400) < 0.001)
        #expect(abs(rect.width - 400 * 16 / 9) < 0.001)
    }

    @Test("box proportions are preserved")
    func preservesProportions() {
        let rect = aspectFillRect(
            normalizedBox: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.3),
            imageAspectRatio: 1,
            viewSize: CGSize(width: 300, height: 300)
        )

        #expect(abs(rect.width - 90) < 0.001)
        #expect(abs(rect.height - 90) < 0.001)
        #expect(abs(rect.minX - 60) < 0.001)
        #expect(abs(rect.minY - 30) < 0.001)
    }

    @Test("aspect-fit letterboxes instead of cropping")
    func fitLeavesMargins() {
        // A 3:4 portrait image in a square view is height-constrained, so it fills the
        // height and leaves bars on the left and right. Nothing is cut off.
        let rect = aspectFitRect(
            normalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageAspectRatio: 3.0 / 4.0,
            viewSize: CGSize(width: 400, height: 400)
        )

        #expect(rect.minX > 0)
        #expect(rect.maxX < 400)
        #expect(rect.minY >= -0.001)
        #expect(rect.maxY <= 400.001)
        #expect(abs(rect.width - 300) < 0.001)
        #expect(abs(rect.height - 400) < 0.001)
    }

    @Test("aspect-fit keeps the centre centred")
    func fitCentreMapsToCentre() {
        let viewSize = CGSize(width: 390, height: 600)
        let rect = aspectFitRect(
            normalizedBox: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1),
            imageAspectRatio: 16.0 / 9.0,
            viewSize: viewSize
        )

        #expect(abs(rect.midX - viewSize.width / 2) < 0.001)
        #expect(abs(rect.midY - viewSize.height / 2) < 0.001)
    }

    @Test("fit and fill agree when the aspect ratios already match")
    func fitEqualsFillWhenAspectsMatch() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let size = CGSize(width: 300, height: 400)

        let fit = aspectFitRect(normalizedBox: box, imageAspectRatio: 0.75, viewSize: size)
        let fill = aspectFillRect(normalizedBox: box, imageAspectRatio: 0.75, viewSize: size)

        #expect(abs(fit.minX - fill.minX) < 0.001)
        #expect(abs(fit.minY - fill.minY) < 0.001)
        #expect(abs(fit.width - fill.width) < 0.001)
        #expect(abs(fit.height - fill.height) < 0.001)
    }

    @Test("degenerate inputs return zero instead of NaN")
    func degenerateInputs() {
        let box = CGRect(x: 0, y: 0, width: 1, height: 1)
        #expect(aspectFillRect(normalizedBox: box, imageAspectRatio: 0, viewSize: CGSize(width: 10, height: 10)) == .zero)
        #expect(aspectFillRect(normalizedBox: box, imageAspectRatio: 1, viewSize: .zero) == .zero)
        #expect(aspectFitRect(normalizedBox: box, imageAspectRatio: 0, viewSize: CGSize(width: 10, height: 10)) == .zero)
        #expect(aspectFitRect(normalizedBox: box, imageAspectRatio: 1, viewSize: .zero) == .zero)
    }
}
