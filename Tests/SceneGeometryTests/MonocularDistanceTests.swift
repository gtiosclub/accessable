import CoreGraphics
import ImageIO
import Foundation
import Testing
import simd

@testable import SceneGeometry

// T33 — distance without a depth sensor: from an object's floor contact, and from how large
// something of known size appears.
//
// The scene is deliberately exactly calculable. A pinhole camera 1.3 m above a level floor,
// looking along -Z with no rotation, image 1920x1440 and focal length 1440 px in both axes,
// principal point at the centre. Orientation is `.up` so upright and sensor coordinates are
// the same and the geometry under test is not tangled up with the rotation mapping.

private let imageWidth = 1920
private let imageHeight = 1440
private let focal: Float = 1440
private let cameraHeight: Float = 1.3

private let intrinsics = CameraIntrinsics(
    focalX: focal, focalY: focal,
    principalX: Float(imageWidth) / 2, principalY: Float(imageHeight) / 2,
    imageWidth: imageWidth, imageHeight: imageHeight
)

/// Identity rotation, camera lifted to `cameraHeight`.
private let cameraTransform = simd_float4x4(columns: (
    SIMD4<Float>(1, 0, 0, 0),
    SIMD4<Float>(0, 1, 0, 0),
    SIMD4<Float>(0, 0, 1, 0),
    SIMD4<Float>(0, cameraHeight, 0, 1)
))

private let corridor = WalkingCorridor(
    origin: [0, cameraHeight, 0], forward: [0, 0, -1], right: [1, 0, 0],
    width: 0.9, maxDistance: 10
)

private func floor(measured: Bool) -> FloorEstimate {
    FloorEstimate(
        plane: Plane3D(normal: [0, 1, 0], point: [0, 0, 0]),
        isMeasured: measured,
        cameraHeight: cameraHeight
    )
}

/// The normalized coordinate addressing the centre of pixel `index`.
private func normalized(pixel index: Float, of extent: Int) -> CGFloat {
    CGFloat((index + 0.5) / Float(extent))
}

@Suite("T33 — distance from floor contact")
struct GroundContactDistanceTests {
    /// A contact row 468 px below the principal point points down at atan(468/1440), so it
    /// meets a floor 1.3 m down at 1.3 * 1440 / 468 = 4.0 m horizontally, which is
    /// sqrt(1.3² + 4²) = 4.206 m from the camera.
    @Test("a box standing on the floor is placed where the ray meets it")
    func contactDistance() throws {
        var tuning = GroundContactTuning.default
        // The real inset trims a few per cent off the box; zero isolates the geometry.
        tuning.contactInset = 0

        let contactRow = Float(imageHeight) / 2 + 468
        let box = CGRect(
            x: 0.45, y: 0.6,
            width: 0.1, height: normalized(pixel: contactRow, of: imageHeight) - 0.6
        )
        let estimate = try #require(groundContactDistance(
            box: box, orientation: .up, floor: floor(measured: true), corridor: corridor,
            intrinsics: intrinsics, cameraTransform: cameraTransform, tuning: tuning
        ))

        #expect(abs(estimate.meters - 4.206) < 0.02)
        // The intersection is on the floor, which is the whole claim being made.
        #expect(abs(estimate.position.y) < 0.01)
        #expect(abs(estimate.position.z + 4.0) < 0.02)
        // 6% of 4.2 m, which is above the 8 cm floor on the error.
        #expect(abs(estimate.plusMinus - 4.206 * 0.06) < 0.01)
    }

    @Test("a remembered floor is reported as less certain than a measured one")
    func assumedFloorWidensTheError() throws {
        var tuning = GroundContactTuning.default
        tuning.contactInset = 0
        let contactRow = Float(imageHeight) / 2 + 468
        let box = CGRect(
            x: 0.45, y: 0.6,
            width: 0.1, height: normalized(pixel: contactRow, of: imageHeight) - 0.6
        )

        let measured = try #require(groundContactDistance(
            box: box, orientation: .up, floor: floor(measured: true), corridor: corridor,
            intrinsics: intrinsics, cameraTransform: cameraTransform, tuning: tuning
        ))
        let assumed = try #require(groundContactDistance(
            box: box, orientation: .up, floor: floor(measured: false), corridor: corridor,
            intrinsics: intrinsics, cameraTransform: cameraTransform, tuning: tuning
        ))

        // Same geometry, so the same distance; only the confidence in it changes.
        #expect(abs(measured.meters - assumed.meters) < 0.001)
        #expect(assumed.plusMinus > measured.plusMinus)
    }

    @Test("a box whose bottom is above the horizon has no floor contact")
    func aboveHorizonIsNil() {
        // Entirely in the upper half of the frame: the ray rises and never meets the floor.
        let box = CGRect(x: 0.45, y: 0.1, width: 0.1, height: 0.2)
        #expect(groundContactDistance(
            box: box, orientation: .up, floor: floor(measured: true), corridor: corridor,
            intrinsics: intrinsics, cameraTransform: cameraTransform
        ) == nil)
    }

    @Test("a contact just below the horizon is too far to report")
    func beyondMaxDistanceIsNil() {
        var tuning = GroundContactTuning.default
        tuning.contactInset = 0
        // 10 px below centre: the ray grazes the floor about 187 m out.
        let contactRow = Float(imageHeight) / 2 + 10
        let box = CGRect(
            x: 0.45, y: 0.45,
            width: 0.1, height: normalized(pixel: contactRow, of: imageHeight) - 0.45
        )
        #expect(groundContactDistance(
            box: box, orientation: .up, floor: floor(measured: true), corridor: corridor,
            intrinsics: intrinsics, cameraTransform: cameraTransform, tuning: tuning
        ) == nil)
    }

    /// The box is converted to sensor coordinates before being unprojected, not rescaled in
    /// place. Sampling the wrong part of the scene is the failure this guards: it produces a
    /// plausible number rather than an error, so only an explicit check catches it.
    @Test("the contact point goes through the orientation mapping")
    func contactPointIsMapped() throws {
        var tuning = GroundContactTuning.default
        tuning.contactInset = 0
        let box = CGRect(x: 0.4, y: 0.55, width: 0.2, height: 0.25)

        let estimate = try #require(groundContactDistance(
            box: box, orientation: .up, floor: floor(measured: true), corridor: corridor,
            intrinsics: intrinsics, cameraTransform: cameraTransform, tuning: tuning
        ))
        // The same answer, worked out by mapping the contact point by hand first.
        let mapped = CGImagePropertyOrientation.up.sensorPoint(
            fromUpright: CGPoint(x: box.midX, y: box.maxY)
        )
        let expected = try #require(floorIntersection(
            sensorPoint: mapped, intrinsics: intrinsics, cameraTransform: cameraTransform,
            plane: floor(measured: true).plane
        ))
        #expect(abs(estimate.position.z - expected.z) < 0.001)
    }

    @Test("mirroring the frame leaves a centred box where it was")
    func mirroringACentredBoxChangesNothing() throws {
        // `.upMirrored` only flips x, and the box is centred on x, so the geometry is
        // untouched. A mapping applied to the wrong axis would show up here.
        let box = CGRect(x: 0.4, y: 0.55, width: 0.2, height: 0.25)
        let plain = try #require(groundContactDistance(
            box: box, orientation: .up, floor: floor(measured: true), corridor: corridor,
            intrinsics: intrinsics, cameraTransform: cameraTransform
        ))
        let mirrored = try #require(groundContactDistance(
            box: box, orientation: .upMirrored, floor: floor(measured: true), corridor: corridor,
            intrinsics: intrinsics, cameraTransform: cameraTransform
        ))
        #expect(abs(plain.meters - mirrored.meters) < 0.001)
    }

    /// With the camera pose held in its landscape frame, an upside-down mapping sends a box
    /// low in the upright image to the top of the sensor image, so the ray rises and meets
    /// no floor. Refusing to answer is correct; inventing a distance would not be.
    @Test("an inverted mapping is not quietly given a distance")
    func invertedMappingHasNoContact() {
        let box = CGRect(x: 0.4, y: 0.55, width: 0.2, height: 0.25)
        #expect(groundContactDistance(
            box: box, orientation: .down, floor: floor(measured: true), corridor: corridor,
            intrinsics: intrinsics, cameraTransform: cameraTransform
        ) == nil)
    }
}

@Suite("T33 — distance from known object size")
struct ObjectSizePriorTests {
    /// Rows symmetric about the principal point make the subtended angle exact:
    /// 306 px either side gives 2·atan(306/1440), so 2·tan(θ/2) = 0.425 and a person
    /// 1.45–1.95 m tall is 3.41–4.59 m away.
    @Test("a person's box gives the distances consistent with adult heights")
    func personRange() throws {
        let half: Float = 306
        let centre = Float(imageHeight) / 2
        let top = normalized(pixel: centre - half, of: imageHeight)
        let bottom = normalized(pixel: centre + half, of: imageHeight)
        let box = CGRect(x: 0.4, y: top, width: 0.2, height: bottom - top)

        let prior = try #require(ObjectSizePriors.prior(for: "person"))
        let range = try #require(distanceRange(
            box: box, orientation: .up, prior: prior, intrinsics: intrinsics
        ))

        #expect(abs(range.lowerBound - 1.45 / 0.425) < 0.05)
        #expect(abs(range.upperBound - 1.95 / 0.425) < 0.05)
        // The midpoint is the 4 m the box was built for.
        #expect(abs((range.lowerBound + range.upperBound) / 2 - 4.0) < 0.05)
    }

    @Test("a nearer object subtends more and so reads nearer")
    func biggerBoxIsNearer() throws {
        let prior = try #require(ObjectSizePriors.prior(for: "person"))
        let near = try #require(distanceRange(
            box: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.7),
            orientation: .up, prior: prior, intrinsics: intrinsics
        ))
        let far = try #require(distanceRange(
            box: CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.15),
            orientation: .up, prior: prior, intrinsics: intrinsics
        ))
        #expect(near.upperBound < far.lowerBound)
    }

    @Test("a box clipped by the frame edge is refused", arguments: [
        CGRect(x: 0.4, y: 0.0, width: 0.2, height: 0.5),      // cut off at the top
        CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.5),      // cut off at the bottom
        CGRect(x: 0.0, y: 0.3, width: 0.2, height: 0.4),      // cut off at the left
    ])
    func truncatedBoxIsNil(box: CGRect) throws {
        let prior = try #require(ObjectSizePriors.prior(for: "person"))
        #expect(distanceRange(box: box, orientation: .up, prior: prior, intrinsics: intrinsics) == nil)
    }

    @Test("labels without a usable height prior have none")
    func unknownLabelsHaveNoPrior() {
        #expect(ObjectSizePriors.prior(for: "obstacle") == nil)
        #expect(ObjectSizePriors.prior(for: "vase") == nil)
        // Lookup ignores case, since labels arrive capitalized in places.
        #expect(ObjectSizePriors.prior(for: "Person")?.label == "person")
    }
}

@Suite("T33 — combining the two estimates")
struct CombinedDistanceTests {
    private func contact(_ meters: Float, _ plusMinus: Float) -> GroundContactEstimate {
        GroundContactEstimate(position: [0, 0, -meters], meters: meters, plusMinus: plusMinus)
    }

    /// The uncertainty, which arrives as a `Float` widened to `Double`, so it is never
    /// exactly the decimal written here.
    private func plusMinus(of accuracy: DistanceAccuracy) -> Double? {
        guard case .estimated(let value) = accuracy else { return nil }
        return value
    }

    @Test("agreeing estimates narrow to their overlap")
    func overlapIsTighter() throws {
        // 4.0 ± 0.4 against 3.4–4.6: the overlap is 3.6–4.4, tighter than either.
        let combined = try #require(combinedDistance(
            groundContact: contact(4.0, 0.4), sizeRange: 3.4 ... 4.6
        ))
        #expect(abs(combined.meters - 4.0) < 0.01)
        #expect(abs(try #require(plusMinus(of: combined.accuracy)) - 0.4) < 0.001)
    }

    @Test("disagreeing estimates widen to span both, rather than one being picked")
    func disagreementWidens() throws {
        // 2.0 ± 0.2 against 5.0–6.0 cannot both be right, and the answer says so: the span
        // is 1.8–6.0, so 3.9 ± 2.1 — a number with error bars wide enough to be useless,
        // which is the honest report rather than a confident pick between the two.
        let combined = try #require(combinedDistance(
            groundContact: contact(2.0, 0.2), sizeRange: 5.0 ... 6.0
        ))
        #expect(abs(combined.meters - 3.9) < 0.01)
        #expect(abs(try #require(plusMinus(of: combined.accuracy)) - 2.1) < 0.01)
    }

    @Test("either source alone is enough")
    func singleSource() throws {
        let contactOnly = try #require(combinedDistance(groundContact: contact(3.0, 0.2), sizeRange: nil))
        #expect(abs(contactOnly.meters - 3.0) < 0.01)

        let sizeOnly = try #require(combinedDistance(groundContact: nil, sizeRange: 2.0 ... 3.0))
        #expect(abs(sizeOnly.meters - 2.5) < 0.01)
        #expect(abs(try #require(plusMinus(of: sizeOnly.accuracy)) - 0.5) < 0.001)
    }

    @Test("no estimate at all stays nil, rather than becoming a confident zero")
    func noSourceIsNil() {
        #expect(combinedDistance(groundContact: nil, sizeRange: nil) == nil)
    }

    @Test("an estimate is never reported as more precise than the box allows")
    func errorHasAFloor() throws {
        let combined = try #require(combinedDistance(
            groundContact: contact(3.0, 0.01), sizeRange: 2.99 ... 3.01
        ))
        #expect(abs(try #require(plusMinus(of: combined.accuracy)) - 0.08) < 0.001)
    }
}

@Suite("T33 — what warnings act on")
struct CautiousDistanceTests {
    private func detection(distance: Double?, accuracy: DistanceAccuracy?) -> Detection {
        Detection(
            label: "chair", confidence: 0.9, boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            distance: distance, distanceAccuracy: accuracy, origin: .model, isHazard: true
        )
    }

    @Test("a measured distance is used exactly, so LiDAR behaviour is unchanged")
    func measuredIsUnchanged() {
        #expect(detection(distance: 2.0, accuracy: .measured).cautiousDistance == 2.0)
        // No accuracy recorded at all is treated the same way, for detections made before T33.
        #expect(detection(distance: 2.0, accuracy: nil).cautiousDistance == 2.0)
    }

    @Test("an estimate warns from the near end of its uncertainty")
    func estimateIsCautious() throws {
        let value = try #require(detection(distance: 2.0, accuracy: .estimated(plusMinus: 0.5)).cautiousDistance)
        #expect(abs(value - 1.5) < 0.001)
    }

    @Test("the cautious distance never goes negative")
    func neverNegative() throws {
        let value = try #require(detection(distance: 0.3, accuracy: .estimated(plusMinus: 1.0)).cautiousDistance)
        #expect(value == 0)
    }

    @Test("no distance means nothing to act on")
    func noDistance() {
        #expect(detection(distance: nil, accuracy: nil).cautiousDistance == nil)
    }
}
