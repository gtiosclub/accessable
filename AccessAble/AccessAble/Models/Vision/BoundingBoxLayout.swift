import CoreGraphics
import Foundation

// Mapping a normalized detection box onto an on-screen camera preview (1.1).
//
// Pure geometry, kept out of the view so it can be unit-tested — getting this wrong draws
// boxes that are plausibly placed but consistently off, which is hard to spot by eye.

/// The aspect-**fit** counterpart, for a still image shown whole (letterboxed) rather
/// than cropped to fill — what `Image(...).scaledToFit()` does.
func aspectFitRect(
    normalizedBox: CGRect,
    imageAspectRatio: CGFloat,
    viewSize: CGSize
) -> CGRect {
    guard imageAspectRatio > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }

    let viewAspectRatio = viewSize.width / viewSize.height
    // Fit is fill's mirror image: the axis that overflowed now leaves a margin.
    let displayed = imageAspectRatio > viewAspectRatio
        ? CGSize(width: viewSize.width, height: viewSize.width / imageAspectRatio)
        : CGSize(width: viewSize.height * imageAspectRatio, height: viewSize.height)

    return CGRect(
        x: (viewSize.width - displayed.width) / 2 + normalizedBox.minX * displayed.width,
        y: (viewSize.height - displayed.height) / 2 + normalizedBox.minY * displayed.height,
        width: normalizedBox.width * displayed.width,
        height: normalizedBox.height * displayed.height
    )
}

/// Converts a normalized, upright, top-left-origin box into view coordinates for a preview
/// that **aspect-fills** its container (the camera feed is cropped, not letterboxed, which
/// is how `ARSCNView` and `AVCaptureVideoPreviewLayer`'s `.resizeAspectFill` both behave).
///
/// - Parameters:
///   - normalizedBox: As carried by `Detection.boundingBox`.
///   - imageAspectRatio: Width / height of the camera image **after** rotating upright.
///   - viewSize: Size of the preview on screen.
func aspectFillRect(
    normalizedBox: CGRect,
    imageAspectRatio: CGFloat,
    viewSize: CGSize
) -> CGRect {
    guard imageAspectRatio > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }

    // Aspect-fill: the image is scaled until it covers the view, so one axis overflows
    // and the overflow is split evenly as a negative origin.
    let viewAspectRatio = viewSize.width / viewSize.height
    let displayed = imageAspectRatio > viewAspectRatio
        ? CGSize(width: viewSize.height * imageAspectRatio, height: viewSize.height)
        : CGSize(width: viewSize.width, height: viewSize.width / imageAspectRatio)

    let offsetX = (viewSize.width - displayed.width) / 2
    let offsetY = (viewSize.height - displayed.height) / 2

    return CGRect(
        x: offsetX + normalizedBox.minX * displayed.width,
        y: offsetY + normalizedBox.minY * displayed.height,
        width: normalizedBox.width * displayed.width,
        height: normalizedBox.height * displayed.height
    )
}
