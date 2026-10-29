import ARKit
import UIKit
import simd

/// Door and window triangles from the frame's classified mesh anchors, within `range`
/// metres of the camera (T36). Empty when scene reconstruction isn't running.
func classifiedFaceSamples(in frame: ARFrame, range: Float = 8) -> [MeshFaceSample] {
    let c = frame.camera.transform.columns.3
    let cameraPosition = SIMD3(c.x, c.y, c.z)
    var samples: [MeshFaceSample] = []

    for case let anchor as ARMeshAnchor in frame.anchors {
        let a = anchor.transform.columns.3
        // mesh chunks are a few metres across, so skip ones that start far away
        guard simd_distance(SIMD3(a.x, a.y, a.z), cameraPosition) < range + 3 else { continue }

        let geometry = anchor.geometry
        guard let classification = geometry.classification else { continue }
        let faces = geometry.faces
        let vertices = geometry.vertices
        guard faces.bytesPerIndex == 4 else { continue }

        let indexBase = faces.buffer.contents()
        let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
        let classBase = classification.buffer.contents().advanced(by: classification.offset)
        let corners = faces.indexCountPerPrimitive

        for face in 0..<faces.count {
            let raw = classBase.advanced(by: face * classification.stride).load(as: UInt8.self)
            guard let label = structuralLabel(ARMeshClassification(rawValue: Int(raw))) else { continue }

            var sum = SIMD3<Float>.zero
            for corner in 0..<corners {
                let index = indexBase.load(fromByteOffset: (face * corners + corner) * 4, as: UInt32.self)
                let p = vertexBase.advanced(by: Int(index) * vertices.stride).assumingMemoryBound(to: Float.self)
                sum += SIMD3(p[0], p[1], p[2])
            }
            let world = anchor.transform * SIMD4(sum / Float(corners), 1)
            let position = SIMD3(world.x, world.y, world.z)
            guard simd_distance(position, cameraPosition) < range else { continue }
            samples.append(MeshFaceSample(label: label, position: position))
        }
    }
    return samples
}

private func structuralLabel(_ classification: ARMeshClassification?) -> String? {
    switch classification {
    case .door?: "door"
    case .window?: "window"
    default: nil
    }
}

/// Features in front of the camera as `Detection`s, with distance and direction from
/// `heading` and a small box around where they project on screen.
func structuralDetections(
    _ features: [StructuralFeature],
    heading: WalkingCorridor,
    camera: ARCamera,
    orientation: UIInterfaceOrientation,
    viewportSize: CGSize
) -> [Detection] {
    guard viewportSize.width > 0, viewportSize.height > 0 else { return [] }
    return features.compactMap { feature in
        guard simd_dot(feature.center - heading.origin, heading.forward) > 0.3 else { return nil }
        let point = camera.projectPoint(feature.center, orientation: orientation, viewportSize: viewportSize)
        let u = point.x / viewportSize.width
        let v = point.y / viewportSize.height
        guard u.isFinite, v.isFinite, (0...1).contains(u), (0...1).contains(v) else { return nil }

        let box = CGRect(x: max(u - 0.05, 0), y: max(v - 0.1, 0), width: 0.1, height: 0.2)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return Detection(
            label: feature.label,
            confidence: 1,
            boundingBox: box,
            distance: Double(heading.distance(to: feature.center)),
            bearing: heading.bearing(to: feature.center),
            origin: .mesh,
            isHazard: false,
            worldPosition: feature.center
        )
    }
}
