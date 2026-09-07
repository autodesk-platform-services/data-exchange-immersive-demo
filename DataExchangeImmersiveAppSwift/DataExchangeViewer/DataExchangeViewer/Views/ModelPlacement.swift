//
//  ModelPlacement.swift
//  DataExchangeViewer
//

import RealityKit
import simd

/// Where a loaded model goes, for each spatial preview mode.
///
/// Pure functions over a bounding box and the wearer's pose, deliberately separate from
/// `ImmersiveModelView`: the arithmetic here is the part of spatial previewing that is easy to get
/// wrong and impossible to eyeball, and as view-private methods it could only be checked by
/// putting on a headset. `ModelPlacementTests` covers it instead.
enum ModelPlacement {
    /// Caps exceptionally large source geometry independently of the backdrop size. Since the
    /// model's nearest face is placed in front of the wearer, its farthest face can be roughly
    /// twice this distance away; 150 m leaves ample clearance inside the 500 m white sphere.
    static let maximumEnteredModelReach: Float = 150
    /// Scales small geometry up instead. Entering a 20 cm mechanical part at authored scale left
    /// a 20 cm object floating two metres away inside a white sphere with nothing to fly through,
    /// so Enter was effectively a no-op below room scale. Four metres is small enough to take in
    /// at a glance and large enough to move around inside.
    static let minimumEnteredModelReach: Float = 4
    /// The size Place gives the model's largest dimension: close enough for direct hand
    /// interaction, and small enough to sit on a desk.
    static let placedMaximumDimension: Float = 0.65

    /// The wearer's position and heading, reduced to what placement needs.
    struct ViewerFrame: Equatable {
        let position: SIMD3<Float>
        let forward: SIMD3<Float>
    }

    /// Uses only the wearer's yaw so buildings remain vertical even when the person looks up or
    /// down. The fallback matches visionOS's conventional initial immersive coordinate frame.
    static func viewerFrame(from transform: Transform?) -> ViewerFrame {
        guard let transform else {
            return ViewerFrame(position: SIMD3<Float>(0, 1.6, 0), forward: SIMD3<Float>(0, 0, -1))
        }

        let forward3D = -transform.matrix.columns.2
        let horizontal = SIMD3<Float>(forward3D.x, 0, forward3D.z)
        let length = simd_length(horizontal)
        let forward = length > 0.001 ? horizontal / length : SIMD3<Float>(0, 0, -1)
        return ViewerFrame(position: transform.translation, forward: forward)
    }

    /// Places the model's center at a comfortable tabletop height and scales its largest dimension
    /// to `placedMaximumDimension`, leaving it close enough for direct hand interaction.
    ///
    /// Nil for geometry with no extent at all — an empty or unloadable scene — because there is no
    /// scale that would make it visible and the caller is better off leaving the entity where it is.
    static func placedTransform(
        bounds: BoundingBox,
        relativeTo deviceTransform: Transform?
    ) -> Transform? {
        let maxDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard maxDimension > 0 else { return nil }

        let scale = placedMaximumDimension / maxDimension
        let viewer = viewerFrame(from: deviceTransform)
        let rotation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: viewer.forward)
        let desiredCenter = viewer.position + viewer.forward * 1.2 + SIMD3<Float>(0, -0.25, 0)
        let scaledCenter = rotation.act(bounds.center * scale)
        return Transform(
            scale: SIMD3<Float>(repeating: scale),
            rotation: rotation,
            translation: desiredCenter - scaledCenter
        )
    }

    /// Brings the model to a scale someone can walk through, stands its lowest point on the
    /// floor, and places the nearest face two meters in front of the person so they begin
    /// outside the geometry. A building-sized model keeps its authored scale.
    static func enteredTransform(
        bounds: BoundingBox,
        relativeTo deviceTransform: Transform?
    ) -> Transform {
        let halfDepth = bounds.extents.z / 2
        let scale = enteredScale(forReach: enteredReach(of: bounds))
        let viewer = viewerFrame(from: deviceTransform)
        let rotation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: viewer.forward)

        // Put the center of the model's nearest face two meters ahead of the wearer. The y
        // translation remains floor-relative so the building stays upright and grounded.
        let desiredFront = viewer.position + viewer.forward * 2
        let localFront = SIMD3<Float>(bounds.center.x, 0, bounds.center.z + halfDepth) * scale
        let rotatedFront = rotation.act(localFront)

        return Transform(
            scale: SIMD3<Float>(repeating: scale),
            rotation: rotation,
            translation: SIMD3<Float>(
                desiredFront.x - rotatedFront.x,
                -bounds.min.y * scale,
                desiredFront.z - rotatedFront.z
            )
        )
    }

    /// Half the model's diagonal, treating height as a full extent because the model stands on the
    /// floor rather than being centered on the wearer's eye line. The one number Enter's scale is
    /// chosen from.
    static func enteredReach(of bounds: BoundingBox) -> Float {
        let halfWidth = bounds.extents.x / 2
        let halfDepth = bounds.extents.z / 2
        let height = bounds.extents.y
        return (halfWidth * halfWidth + height * height + halfDepth * halfDepth).squareRoot()
    }

    /// Clamped in both directions: a site model is brought inside the backdrop, and anything
    /// smaller than a room is scaled up to a size worth walking through. Only clamping downwards
    /// made Enter a no-op for small parts.
    static func enteredScale(forReach reach: Float) -> Float {
        if reach < 0.0001 {
            return 1
        } else if reach < minimumEnteredModelReach {
            return minimumEnteredModelReach / reach
        } else if reach > maximumEnteredModelReach {
            return maximumEnteredModelReach / reach
        } else {
            return 1
        }
    }
}
