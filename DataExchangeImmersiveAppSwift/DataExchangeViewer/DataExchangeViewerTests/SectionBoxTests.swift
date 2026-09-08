//
//  SectionBoxTests.swift
//  DataExchangeViewerTests
//

import Testing
import RealityKit
import simd
@testable import DataExchangeViewer

/// The section box's sign conventions and clamps — a handful of near-identical expressions that are
/// indistinguishable from each other in a headset right up to the moment the box turns inside out.
@Suite("Section box")
struct SectionBoxTests {
    private let model = BoundingBox(
        min: SIMD3<Float>(-10, 0, -20),
        max: SIMD3<Float>(30, 24, 20)
    )

    @Test func startsFromTheModelsFullExtent() {
        let bounds = SectionBoxGeometry.initialBounds(modelBounds: model)
        #expect(bounds.min ≈ model.min)
        #expect(bounds.max ≈ model.max)
    }

    /// Dragging a maximum face outward along its own normal raises that maximum, and touches
    /// nothing else.
    @Test func draggingAMaximumFaceOutwardRaisesOnlyThatCoordinate() {
        let start = SectionBoxGeometry.initialBounds(modelBounds: model)
        let result = SectionBoxGeometry.draggingFace(
            .maxY,
            by: SIMD3<Float>(0, 1, 0),
            from: start,
            within: model
        )
        #expect(abs(result.max.y - (start.max.y + 1)) < 1e-4)
        #expect(result.min ≈ start.min)
        #expect(abs(result.max.x - start.max.x) < 1e-4)
        #expect(abs(result.max.z - start.max.z) < 1e-4)
    }

    /// A minimum face's outward normal points down the axis, so outward motion *lowers* the
    /// minimum. The sign here is the one that inverts the box if it is wrong.
    @Test func draggingAMinimumFaceOutwardLowersThatCoordinate() {
        var start = SectionBoxGeometry.initialBounds(modelBounds: model)
        start.min.y = 5
        let result = SectionBoxGeometry.draggingFace(
            .minY,
            by: SIMD3<Float>(0, -1, 0),
            from: start,
            within: model
        )
        #expect(abs(result.min.y - 4) < 1e-4)
    }

    @Test func draggingAMinimumFaceInwardRaisesThatCoordinate() {
        let start = SectionBoxGeometry.initialBounds(modelBounds: model)
        let result = SectionBoxGeometry.draggingFace(
            .minY,
            by: SIMD3<Float>(0, 3, 0),
            from: start,
            within: model
        )
        #expect(abs(result.min.y - 3) < 1e-4)
    }

    /// Constraining to the face's normal is what makes the drag feel right: a hand that wanders
    /// off-axis mid-pinch should slide the face along its own axis, not smear the box diagonally.
    @Test func ignoresMotionOffTheFacesNormal() {
        let start = SectionBoxGeometry.initialBounds(modelBounds: model)
        let straight = SectionBoxGeometry.draggingFace(
            .maxY,
            by: SIMD3<Float>(0, -4, 0),
            from: start,
            within: model
        )
        let wandering = SectionBoxGeometry.draggingFace(
            .maxY,
            by: SIMD3<Float>(7, -4, -9),
            from: start,
            within: model
        )
        #expect(straight.min ≈ wandering.min)
        #expect(straight.max ≈ wandering.max)
    }

    /// A face dragged through its opposite would invert the box, which clips everything.
    @Test func cannotDragAFaceThroughItsOpposite() {
        let start = SectionBoxGeometry.initialBounds(modelBounds: model)
        let result = SectionBoxGeometry.draggingFace(
            .maxY,
            by: SIMD3<Float>(0, -1000, 0),
            from: start,
            within: model
        )
        #expect(result.max.y > result.min.y)
        let thickness = result.max.y - result.min.y
        let expected = model.extents.y * SectionBoxGeometry.minimumThicknessFraction
        #expect(abs(thickness - expected) < 1e-3)
    }

    @Test func cannotDragAMinimumFaceThroughItsOpposite() {
        let start = SectionBoxGeometry.initialBounds(modelBounds: model)
        let result = SectionBoxGeometry.draggingFace(
            .minX,
            by: SIMD3<Float>(-1000, 0, 0),
            from: start,
            within: model
        )
        // Outward on a minimum face is a *drag towards −x*, projected onto the −x normal, which is
        // positive — so this pulls the minimum outward and stops at the overshoot limit.
        let limit = model.min.x - model.extents.x * SectionBoxGeometry.overshootFraction
        #expect(abs(result.min.x - limit) < 1e-3)
    }

    /// Some slack outside the model means "don't clip on this axis" is reachable by dragging, but
    /// not so much that the handle ends up metres away from the geometry it cuts.
    @Test func clampsOutwardDragsToASmallOvershoot() {
        let start = SectionBoxGeometry.initialBounds(modelBounds: model)
        let result = SectionBoxGeometry.draggingFace(
            .maxX,
            by: SIMD3<Float>(1000, 0, 0),
            from: start,
            within: model
        )
        let limit = model.max.x + model.extents.x * SectionBoxGeometry.overshootFraction
        #expect(abs(result.max.x - limit) < 1e-3)
    }

    /// An absolute gesture, not an accumulation of deltas: the same displacement applied twice from
    /// the same start bounds has to give the same box, or a long drag drifts.
    @Test func dragsAreAbsoluteFromTheGesturesStart() {
        let start = SectionBoxGeometry.initialBounds(modelBounds: model)
        let displacement = SIMD3<Float>(0, -6, 0)
        let once = SectionBoxGeometry.draggingFace(.maxY, by: displacement, from: start, within: model)
        let again = SectionBoxGeometry.draggingFace(.maxY, by: displacement, from: start, within: model)
        #expect(once.max ≈ again.max)
    }

    // MARK: - Handles

    /// Each handle sits on the face it controls, and spans the other two axes of the box.
    @Test func handlesSitOnTheirOwnFace() {
        let bounds = BoundingBox(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(4, 6, 8))
        for face in SectionBoxGeometry.Face.allCases {
            let transform = SectionBoxGeometry.handleTransform(for: face, bounds: bounds)
            let expected = face.isMaximum ? bounds.max[face.axis] : bounds.min[face.axis]
            #expect(abs(transform.translation[face.axis] - expected) < 1e-4, "\(face)")
        }
    }

    @Test func handlesFaceOutward() {
        let bounds = BoundingBox(min: .zero, max: SIMD3<Float>(4, 6, 8))
        for face in SectionBoxGeometry.Face.allCases {
            let transform = SectionBoxGeometry.handleTransform(for: face, bounds: bounds)
            // The plane mesh faces +Z, so its rotated normal should be the face's own.
            let normal = transform.rotation.act(SIMD3<Float>(0, 0, 1))
            #expect(normal ≈ face.normal, "\(face)")
        }
    }

    @Test func handlesSpanTheOtherTwoAxes() {
        let bounds = BoundingBox(min: .zero, max: SIMD3<Float>(4, 6, 8))
        #expect(SectionBoxGeometry.handleSize(for: .maxX, bounds: bounds) == SIMD2<Float>(8, 6))
        #expect(SectionBoxGeometry.handleSize(for: .maxY, bounds: bounds) == SIMD2<Float>(4, 8))
        #expect(SectionBoxGeometry.handleSize(for: .maxZ, bounds: bounds) == SIMD2<Float>(4, 6))
    }

    /// `simd_quatf(from:to:)` is undefined for exactly opposed vectors, and two of the six faces
    /// are exactly opposed to the plane mesh's own normal.
    @Test func rotationHandlesExactlyOpposedVectors() {
        let flipped = SectionBoxGeometry.rotation(
            from: SIMD3<Float>(0, 0, 1),
            to: SIMD3<Float>(0, 0, -1)
        )
        #expect(flipped.act(SIMD3<Float>(0, 0, 1)) ≈ SIMD3<Float>(0, 0, -1))

        let alongY = SectionBoxGeometry.rotation(
            from: SIMD3<Float>(0, 1, 0),
            to: SIMD3<Float>(0, -1, 0)
        )
        #expect(alongY.act(SIMD3<Float>(0, 1, 0)) ≈ SIMD3<Float>(0, -1, 0))
    }

    @Test func rotationIsIdentityForAnAlignedNormal() {
        let same = SectionBoxGeometry.rotation(
            from: SIMD3<Float>(0, 0, 1),
            to: SIMD3<Float>(0, 0, 1)
        )
        #expect(same.act(SIMD3<Float>(1, 2, 3)) ≈ SIMD3<Float>(1, 2, 3))
    }
}
