//
//  SectionBoxGeometry.swift
//  DataExchangeViewer
//

import Foundation
import RealityKit
import simd

/// The six faces of a section box, and the arithmetic for dragging one.
///
/// Split out from `SectionBoxTool` for the same reason `ModelPlacement` is split out of the views:
/// "drag this face outward and the box follows, but never past the opposite face" is a handful of
/// sign conventions that are indistinguishable from each other in a headset until the box turns
/// inside out. `SectionBoxTests` covers them.
enum SectionBoxGeometry {
    /// One face of the box, identified by which coordinate of `bounds` it controls.
    enum Face: String, CaseIterable, Identifiable, Sendable {
        case minX, maxX, minY, maxY, minZ, maxZ

        var id: Self { self }

        /// Outward-pointing normal in the model's own space. Drag displacement is projected onto
        /// this, which is what makes a face slide along its own axis instead of smearing the box
        /// diagonally after a hand that wandered.
        var normal: SIMD3<Float> {
            switch self {
            case .minX: [-1, 0, 0]
            case .maxX: [1, 0, 0]
            case .minY: [0, -1, 0]
            case .maxY: [0, 1, 0]
            case .minZ: [0, 0, -1]
            case .maxZ: [0, 0, 1]
            }
        }

        /// 0 = x, 1 = y, 2 = z.
        var axis: Int {
            switch self {
            case .minX, .maxX: 0
            case .minY, .maxY: 1
            case .minZ, .maxZ: 2
            }
        }

        /// Whether this face controls `bounds.max` rather than `bounds.min`.
        var isMaximum: Bool {
            switch self {
            case .maxX, .maxY, .maxZ: true
            case .minX, .minY, .minZ: false
            }
        }

        var accessibilityName: String {
            switch self {
            case .minX: String(localized: "Left face")
            case .maxX: String(localized: "Right face")
            case .minY: String(localized: "Bottom face")
            case .maxY: String(localized: "Top face")
            case .minZ: String(localized: "Back face")
            case .maxZ: String(localized: "Front face")
            }
        }
    }

    /// The thinnest slice the box may be reduced to, as a fraction of the model's extent on that
    /// axis. Stops a face being dragged through its opposite and inverting the box.
    static let minimumThicknessFraction: Float = 0.01

    /// How far outside the model the box may be pulled, as a fraction of its extent. A little slack
    /// means "no clipping on this axis" is reachable by dragging rather than only by turning the
    /// tool off.
    static let overshootFraction: Float = 0.05

    /// The box a freshly enabled section starts from: the model's own bounds, so enabling the tool
    /// clips nothing and the person cuts inward from a state they recognise.
    static func initialBounds(modelBounds: BoundingBox) -> BoundingBox {
        modelBounds
    }

    /// Applies a drag to one face.
    ///
    /// - Parameters:
    ///   - displacement: the drag so far, already in the model's coordinate space.
    ///   - startBounds: the box as it was when the drag began, so the gesture stays absolute — an
    ///     incremental delta accumulates float error over a long drag and drifts.
    static func draggingFace(
        _ face: Face,
        by displacement: SIMD3<Float>,
        from startBounds: BoundingBox,
        within modelBounds: BoundingBox
    ) -> BoundingBox {
        // Only motion along the face's own normal counts; the rest of the hand's travel is ignored.
        let along = simd_dot(displacement, face.normal)
        let axis = face.axis

        let extent = max(modelBounds.extents[axis], 0.001)
        let slack = extent * overshootFraction
        let minimumThickness = extent * minimumThicknessFraction

        var min = startBounds.min
        var max = startBounds.max

        if face.isMaximum {
            // Outward along +axis raises the maximum.
            let lowerLimit = min[axis] + minimumThickness
            let upperLimit = modelBounds.max[axis] + slack
            max[axis] = Swift.min(Swift.max(startBounds.max[axis] + along, lowerLimit), upperLimit)
        } else {
            // Outward along -axis *lowers* the minimum, so the projection is subtracted.
            let upperLimit = max[axis] - minimumThickness
            let lowerLimit = modelBounds.min[axis] - slack
            min[axis] = Swift.max(Swift.min(startBounds.min[axis] - along, upperLimit), lowerLimit)
        }

        return BoundingBox(min: min, max: max)
    }

    /// Where a face's drag affordance sits and how it is oriented, in the model's space.
    ///
    /// The plane mesh is generated in the XY plane facing +Z, so each face needs the rotation that
    /// takes +Z to its own normal — that is the "convert back into the plane's frame" half of the
    /// drag, and it runs after every change so the handle tracks the box it just moved.
    static func handleTransform(for face: Face, bounds: BoundingBox) -> Transform {
        var position = bounds.center
        position[face.axis] = face.isMaximum ? bounds.max[face.axis] : bounds.min[face.axis]

        return Transform(
            scale: .one,
            rotation: rotation(from: [0, 0, 1], to: face.normal),
            translation: position
        )
    }

    /// The width and height a face's affordance needs to span the box, in the model's space.
    static func handleSize(for face: Face, bounds: BoundingBox) -> SIMD2<Float> {
        let extents = bounds.extents
        switch face.axis {
        case 0: return SIMD2<Float>(extents.z, extents.y)
        case 1: return SIMD2<Float>(extents.x, extents.z)
        default: return SIMD2<Float>(extents.x, extents.y)
        }
    }

    /// `simd_quatf(from:to:)` is undefined for exactly opposed vectors, and two of the six faces
    /// are exactly opposed to the plane mesh's own normal — so those get an explicit half turn
    /// rather than whatever a degenerate cross product produces.
    static func rotation(from source: SIMD3<Float>, to destination: SIMD3<Float>) -> simd_quatf {
        let dot = simd_dot(source, destination)
        if dot > 0.9999 {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        if dot < -0.9999 {
            // Any axis perpendicular to `source` gives a valid half turn; Y unless source *is* Y.
            let axis = abs(source.y) > 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            return simd_quatf(angle: .pi, axis: axis)
        }
        return simd_quatf(from: source, to: destination)
    }
}
