//
//  ModelPlacement.swift
//  DataExchangeViewer
//

import RealityKit
import simd

/// Where a loaded model goes, for each preview mode.
///
/// Pure functions over a bounding box and the wearer's pose, deliberately separate from the views:
/// the arithmetic here is the part of spatial previewing that is easy to get wrong and impossible
/// to eyeball, and as view-private methods it could only be checked by putting on a headset.
/// `ModelPlacementTests` covers it instead.
///
/// Every transform returned here is meant for the *wrapper* around the loaded entity, never for the
/// loaded entity itself. RealityKit's USD loader bakes the stage's units and up-axis into the root
/// it hands back, so overwriting that root's transform discards the unit conversion — see
/// `USDUnitScale`.
enum ModelPlacement {
    /// Fraction of each dimension kept as a gap on *each side* between the portal opening and the
    /// edges of the space it occupies, so it reads as a framed opening rather than content that
    /// bleeds to the edges.
    static let portalMarginFraction: Float = 0.025
    /// Depth of the volume the portal looks into, in meters. The portal's clipping volume and the
    /// model's fit are both derived from this one value, so geometry can't escape the frame.
    static let portalDepth: Float = 0.4
    /// Clearance between the model and the walls of the volumetric window, in meters. Keeps the
    /// section-box handles reachable rather than flush against the volume's own edge.
    static let volumeMargin: Float = 0.04

    /// The wearer's position and heading, reduced to what placement needs.
    struct ViewerFrame: Equatable {
        let position: SIMD3<Float>
        let forward: SIMD3<Float>

        /// Where the wearer is standing, on the floor. An immersive space's origin sits at floor
        /// level, so dropping the device anchor's height is all this takes.
        var feet: SIMD3<Float> { SIMD3<Float>(position.x, 0, position.z) }
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

    // MARK: - Portal

    /// Centers the model inside the portal's clipping volume and scales it to fit.
    ///
    /// USDZ files bake in their own arbitrary position and scale, which otherwise lands the model
    /// at or in front of the portal opening instead of receding behind it. Both faces have to stay
    /// inside a volume running from the window plane at z = 0 back to z = -`portalDepth`, so the
    /// model is centered at half that depth and its largest dimension capped at the depth less a
    /// clearance per side — whatever its proportions.
    ///
    /// Nil for geometry with no extent at all, because no scale would make it visible.
    static func portalFitTransform(bounds: BoundingBox, depth: Float = portalDepth) -> Transform? {
        let maxDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard maxDimension > 0, depth > 0 else { return nil }

        let clearance = depth * 0.125
        let scale = (depth - 2 * clearance) / maxDimension
        let scaledCenter = bounds.center * scale
        return Transform(
            scale: SIMD3<Float>(repeating: scale),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            translation: SIMD3<Float>(
                -scaledCenter.x,
                -scaledCenter.y,
                -scaledCenter.z - depth / 2
            )
        )
    }

    /// The clipping volume for `PortalComponent`, matching the frame the model was fitted into.
    /// Centered half a depth behind the opening, because that is where `portalFitTransform` puts
    /// the model.
    static func portalClippingVolume(width: Float, height: Float, depth: Float = portalDepth) -> PortalComponent.Volume {
        PortalComponent.Volume(
            position: SIMD3<Float>(0, 0, -depth / 2),
            extents: SIMD3<Float>(max(width, 0.001), max(height, 0.001), max(depth, 0.001))
        )
    }

    // MARK: - Volume

    /// Fits the model to the volumetric window's bounds, centered on the volume's own origin.
    ///
    /// Recomputed whenever the person resizes the volume, which is the only way its bounds change —
    /// the volume is positioned and sized by them, never programmatically.
    ///
    /// Nil for geometry with no extent, or a volume with none.
    static func volumeFitTransform(
        bounds: BoundingBox,
        volumeExtents: SIMD3<Float>,
        margin: Float = volumeMargin
    ) -> Transform? {
        let extents = bounds.extents
        guard extents.x > 0 || extents.y > 0 || extents.z > 0 else { return nil }

        let available = volumeExtents - SIMD3<Float>(repeating: 2 * margin)
        guard available.x > 0, available.y > 0, available.z > 0 else { return nil }

        // The binding constraint is whichever axis runs out of room first; a per-axis scale would
        // stretch the model to fill the volume, which for a building is worse than a small one.
        var scale = Float.greatestFiniteMagnitude
        for axis in 0..<3 where extents[axis] > 0 {
            scale = min(scale, available[axis] / extents[axis])
        }
        guard scale.isFinite, scale > 0 else { return nil }

        return Transform(
            scale: SIMD3<Float>(repeating: scale),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            translation: -bounds.center * scale
        )
    }

    // MARK: - Immersive

    /// The model's default entry point: the centre of its footprint, at floor level.
    ///
    /// Used when the export carries no authored `entryPoint` prim. Standing someone at the centre
    /// of the ground floor is a defensible default for a building — unlike the bounding box's
    /// actual centre, which for a multi-storey model is in mid-air between floors.
    static func groundFloorEntryPoint(bounds: BoundingBox) -> SIMD3<Float> {
        SIMD3<Float>(bounds.center.x, bounds.min.y, bounds.center.z)
    }

    /// Places the model so `entryPoint` lands at the wearer's feet, at 1:1 scale.
    ///
    /// There is no API to move the person on visionOS, so "put the user at the centre of the
    /// design" is achieved by moving the model instead — this transform is the starting pose of the
    /// world rig that locomotion then drives.
    ///
    /// The rotation is deliberately identity rather than aligned to the wearer's heading. At 1:1
    /// you walk *inside* the geometry, so a building's authored orientation is meaningful, and
    /// yawing it to face whichever way someone happened to be looking when the space opened only
    /// makes the model's north arbitrary. It is also what keeps the model level: an identity
    /// rotation on a loader-levelled entity has the model's up axis along gravity by construction.
    ///
    /// - Parameters:
    ///   - entryPoint: in the loaded model's own coordinate space, before `unitScale`.
    ///   - unitScale: the residual correction from `USDUnitScale`, normally 1.
    static func immersiveEntryTransform(
        entryPoint: SIMD3<Float>,
        unitScale: Float = 1,
        relativeTo deviceTransform: Transform?
    ) -> Transform {
        let viewer = viewerFrame(from: deviceTransform)
        let scale = unitScale > 0 ? unitScale : 1
        return Transform(
            scale: SIMD3<Float>(repeating: scale),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            translation: viewer.feet - entryPoint * scale
        )
    }
}
