//
//  ModelPlacementTests.swift
//  DataExchangeViewerTests
//

import Testing
import RealityKit
import simd
@testable import DataExchangeViewer

@Suite("Model placement")
struct ModelPlacementTests {
    // MARK: - Viewer frame

    @Test func fallsBackToTheConventionalImmersiveFrameWithoutTracking() {
        let frame = ModelPlacement.viewerFrame(from: nil)
        #expect(frame.position ≈ SIMD3<Float>(0, 1.6, 0))
        #expect(frame.forward ≈ SIMD3<Float>(0, 0, -1))
    }

    @Test func readsThePositionAndHeadingFromTheDevicePose() {
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let frame = ModelPlacement.viewerFrame(
            from: Transform(rotation: rotation, translation: SIMD3<Float>(1, 1.5, -2))
        )
        #expect(frame.position ≈ SIMD3<Float>(1, 1.5, -2))
        #expect(frame.forward ≈ SIMD3<Float>(-1, 0, 0))
    }

    /// Pitch is deliberately discarded: a building placed from a downward-looking pose would
    /// otherwise be tipped over.
    @Test func discardsPitchFromTheHeading() {
        let pitch = simd_quatf(angle: -.pi / 4, axis: SIMD3<Float>(1, 0, 0))
        let frame = ModelPlacement.viewerFrame(from: Transform(rotation: pitch))
        #expect(frame.forward ≈ SIMD3<Float>(0, 0, -1))
    }

    /// Looking straight down leaves no horizontal component to normalize.
    @Test func usesTheDefaultHeadingWhenLookingStraightDown() {
        let lookingDown = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let frame = ModelPlacement.viewerFrame(from: Transform(rotation: lookingDown))
        #expect(frame.forward ≈ SIMD3<Float>(0, 0, -1))
    }

    /// An immersive space's origin is at floor level, so the wearer's feet are their head position
    /// with the height dropped.
    @Test func projectsTheViewerOntoTheFloor() {
        let frame = ModelPlacement.viewerFrame(
            from: Transform(translation: SIMD3<Float>(0.4, 1.62, -1.1))
        )
        #expect(frame.feet ≈ SIMD3<Float>(0.4, 0, -1.1))
    }

    // MARK: - Portal

    /// Both faces of the model have to stay inside the portal's volume, which runs from the window
    /// plane at z = 0 back to z = −depth. A fixed size at a fixed depth would push the far face of
    /// a cube-ish model straight out through the back.
    @Test func portalKeepsBothFacesInsideTheVolume() throws {
        let depth = ModelPlacement.portalDepth
        // Deliberately off-origin and non-uniform, to catch a fit that positions the origin.
        let bounds = BoundingBox(min: SIMD3<Float>(4, 4, 4), max: SIMD3<Float>(6, 8, 5))
        let transform = try #require(ModelPlacement.portalFitTransform(bounds: bounds, depth: depth))

        let near = world(SIMD3<Float>(bounds.center.x, bounds.center.y, bounds.max.z), in: transform)
        let far = world(SIMD3<Float>(bounds.center.x, bounds.center.y, bounds.min.z), in: transform)
        #expect(near.z < 0)
        #expect(far.z > -depth)
    }

    @Test func portalCentersTheModelInTheOpening() throws {
        let bounds = BoundingBox(min: SIMD3<Float>(10, -3, 2), max: SIMD3<Float>(14, 1, 6))
        let transform = try #require(ModelPlacement.portalFitTransform(bounds: bounds))

        let center = world(bounds.center, in: transform)
        #expect(abs(center.x) < 1e-4)
        #expect(abs(center.y) < 1e-4)
        #expect(abs(center.z - -ModelPlacement.portalDepth / 2) < 1e-4)
    }

    @Test func portalDeclinesGeometryWithNoExtent() {
        let empty = BoundingBox(min: .zero, max: .zero)
        #expect(ModelPlacement.portalFitTransform(bounds: empty) == nil)
    }

    /// The clipping volume has to enclose the same frame the model was fitted into, or the fit and
    /// the clip disagree and geometry vanishes at the edges.
    @Test func portalClippingVolumeMatchesTheFittedFrame() {
        let volume = ModelPlacement.portalClippingVolume(width: 0.8, height: 0.5)
        #expect(volume.extents ≈ SIMD3<Float>(0.8, 0.5, ModelPlacement.portalDepth))
        #expect(volume.position ≈ SIMD3<Float>(0, 0, -ModelPlacement.portalDepth / 2))
    }

    // MARK: - Volume

    @Test func volumeFitsTheBindingAxisAndCentersTheModel() throws {
        // 40 m wide, 12 m tall, 20 m deep: width is what runs out of room first in a cubic volume.
        let bounds = BoundingBox(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(40, 12, 20))
        let extents = SIMD3<Float>(1, 1, 1)
        let margin = ModelPlacement.volumeMargin
        let transform = try #require(
            ModelPlacement.volumeFitTransform(bounds: bounds, volumeExtents: extents, margin: margin)
        )

        let expectedScale = (1 - 2 * margin) / 40
        #expect(abs(transform.scale.x - expectedScale) < 1e-6)
        #expect(world(bounds.center, in: transform) ≈ .zero)
    }

    /// Uniform, not per-axis: filling the volume on every axis would stretch the building.
    @Test func volumeScalesUniformly() throws {
        let bounds = BoundingBox(min: .zero, max: SIMD3<Float>(10, 2, 2))
        let transform = try #require(
            ModelPlacement.volumeFitTransform(bounds: bounds, volumeExtents: SIMD3<Float>(1, 1, 1))
        )
        #expect(transform.scale.x == transform.scale.y)
        #expect(transform.scale.y == transform.scale.z)
    }

    /// Every axis of the fitted model has to end up inside the volume, margin included.
    @Test func volumeFitLeavesTheModelInsideTheBounds() throws {
        let bounds = BoundingBox(min: SIMD3<Float>(-3, 0, -80), max: SIMD3<Float>(50, 30, 4))
        let extents = SIMD3<Float>(1.2, 0.8, 1.6)
        let transform = try #require(
            ModelPlacement.volumeFitTransform(bounds: bounds, volumeExtents: extents)
        )

        let scaled = bounds.extents * transform.scale.x
        let available = extents - SIMD3<Float>(repeating: 2 * ModelPlacement.volumeMargin)
        #expect(scaled.x <= available.x + 1e-5)
        #expect(scaled.y <= available.y + 1e-5)
        #expect(scaled.z <= available.z + 1e-5)
    }

    /// A volume smaller than twice the margin has no usable room, and a scale derived from it would
    /// be negative — which mirrors the model through the origin rather than making it small.
    @Test func volumeDeclinesAVolumeWithNoRoom() {
        let bounds = BoundingBox(min: .zero, max: SIMD3<Float>(1, 1, 1))
        #expect(
            ModelPlacement.volumeFitTransform(
                bounds: bounds,
                volumeExtents: SIMD3<Float>(0.01, 0.01, 0.01)
            ) == nil
        )
    }

    @Test func volumeDeclinesGeometryWithNoExtent() {
        let empty = BoundingBox(min: .zero, max: .zero)
        #expect(
            ModelPlacement.volumeFitTransform(
                bounds: empty,
                volumeExtents: SIMD3<Float>(1, 1, 1)
            ) == nil
        )
    }

    // MARK: - Immersive

    /// The default entry point is the middle of the footprint at floor level — not the bounding
    /// box's centre, which for a multi-storey model is in mid-air between floors.
    @Test func groundFloorEntryPointSitsOnTheFloorAtTheFootprintCentre() {
        let bounds = BoundingBox(min: SIMD3<Float>(-10, 0, -5), max: SIMD3<Float>(30, 24, 15))
        let entry = ModelPlacement.groundFloorEntryPoint(bounds: bounds)
        #expect(entry ≈ SIMD3<Float>(10, 0, 5))
    }

    @Test func immersiveEntryPutsTheEntryPointAtTheWearersFeet() {
        let device = Transform(translation: SIMD3<Float>(1.2, 1.6, -0.4))
        let entryPoint = SIMD3<Float>(10, 0, 5)
        let transform = ModelPlacement.immersiveEntryTransform(
            entryPoint: entryPoint,
            relativeTo: device
        )

        let placed = world(entryPoint, in: transform)
        #expect(placed ≈ SIMD3<Float>(1.2, 0, -0.4))
    }

    /// 1:1 is the whole point of the mode. Anything other than unity scale here means a metre in
    /// the model is not a metre in the room.
    @Test func immersiveEntryIsOneToOne() {
        let transform = ModelPlacement.immersiveEntryTransform(entryPoint: .zero, relativeTo: nil)
        #expect(transform.scale ≈ SIMD3<Float>(1, 1, 1))
    }

    /// A residual unit correction, if there ever is one, has to scale the entry offset too —
    /// otherwise the model is the right size but standing in the wrong place.
    @Test func immersiveEntryAppliesAResidualUnitScale() {
        let entryPoint = SIMD3<Float>(1000, 0, 0)
        let transform = ModelPlacement.immersiveEntryTransform(
            entryPoint: entryPoint,
            unitScale: 0.001,
            relativeTo: Transform(translation: SIMD3<Float>(0, 1.6, 0))
        )
        #expect(transform.scale ≈ SIMD3<Float>(repeating: 0.001))
        #expect(world(entryPoint, in: transform) ≈ .zero)
    }

    /// Rotation is identity on purpose: at 1:1 you walk inside the geometry, so yawing the building
    /// to face whichever way someone happened to be looking makes its north arbitrary. Identity is
    /// also what keeps a loader-levelled model's up axis along gravity.
    @Test func immersiveEntryLeavesTheModelUprightAndUnrotated() {
        let tilted = Transform(
            rotation: simd_quatf(angle: .pi / 3, axis: simd_normalize(SIMD3<Float>(1, 1, 0))),
            translation: SIMD3<Float>(0, 1.6, 0)
        )
        let transform = ModelPlacement.immersiveEntryTransform(entryPoint: .zero, relativeTo: tilted)
        #expect(transform.rotation.act(SIMD3<Float>(0, 1, 0)) ≈ SIMD3<Float>(0, 1, 0))
        #expect(transform.rotation.act(SIMD3<Float>(0, 0, -1)) ≈ SIMD3<Float>(0, 0, -1))
    }

    @Test func immersiveEntryRejectsANonPositiveUnitScale() {
        let transform = ModelPlacement.immersiveEntryTransform(
            entryPoint: .zero,
            unitScale: 0,
            relativeTo: nil
        )
        #expect(transform.scale ≈ SIMD3<Float>(1, 1, 1))
    }
}

// MARK: - Helpers

/// Where a point in the model's own coordinates ends up once the transform is applied.
private func world(_ point: SIMD3<Float>, in transform: Transform) -> SIMD3<Float> {
    transform.translation + transform.rotation.act(point * transform.scale)
}

infix operator ≈: ComparisonPrecedence

/// Component-wise comparison with a tolerance, since every value here is the result of
/// trigonometry on `Float`.
func ≈ (lhs: SIMD3<Float>, rhs: SIMD3<Float>) -> Bool {
    simd_length(lhs - rhs) < 1e-4
}
