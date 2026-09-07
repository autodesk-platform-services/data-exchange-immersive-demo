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

    @Test func viewerFrameKeepsPositionAndYaw() {
        let yaw = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let frame = ModelPlacement.viewerFrame(
            from: Transform(rotation: yaw, translation: SIMD3<Float>(1, 1.7, -2))
        )
        #expect(frame.position ≈ SIMD3<Float>(1, 1.7, -2))
        // A quarter turn to the left about +Y points -Z towards -X.
        #expect(frame.forward ≈ SIMD3<Float>(-1, 0, 0))
    }

    /// Pitch is deliberately discarded: a building placed from a downward-looking pose would
    /// otherwise be tilted into the floor.
    @Test func viewerFrameDropsPitchAndStaysNormalized() {
        let pitch = simd_quatf(angle: -.pi / 4, axis: SIMD3<Float>(1, 0, 0))
        let frame = ModelPlacement.viewerFrame(from: Transform(rotation: pitch))
        #expect(frame.forward.y == 0)
        #expect(abs(simd_length(frame.forward) - 1) < 1e-5)
        #expect(frame.forward ≈ SIMD3<Float>(0, 0, -1))
    }

    /// Looking straight down leaves no horizontal component to normalize.
    @Test func viewerFrameFallsBackWhenLookingStraightDown() {
        let lookingDown = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let frame = ModelPlacement.viewerFrame(from: Transform(rotation: lookingDown))
        #expect(frame.forward ≈ SIMD3<Float>(0, 0, -1))
    }

    // MARK: - Place

    @Test func placeScalesTheLargestDimensionToTabletopSize() throws {
        let bounds = BoundingBox(min: SIMD3<Float>(-1, -2, -0.5), max: SIMD3<Float>(1, 2, 0.5))
        let transform = try #require(ModelPlacement.placedTransform(bounds: bounds, relativeTo: nil))
        // The largest extent is 4 m tall, so 0.65 / 4.
        #expect(abs(transform.scale.x - 0.65 / 4) < 1e-6)
        #expect(transform.scale.x == transform.scale.y)
        #expect(transform.scale.y == transform.scale.z)

        let scaledExtents = bounds.extents * transform.scale.x
        #expect(abs(max(scaledExtents.x, scaledExtents.y, scaledExtents.z) - 0.65) < 1e-5)
    }

    /// The model's *visual* center — not its origin, which authored geometry often puts far from
    /// the middle — is what has to end up in front of the wearer.
    @Test func placePutsTheModelCenterInFrontOfTheViewer() throws {
        // Bounds deliberately far off-origin, to catch a placement that positions the origin.
        let bounds = BoundingBox(min: SIMD3<Float>(10, 20, 30), max: SIMD3<Float>(11, 21, 31))
        let device = Transform(translation: SIMD3<Float>(0, 1.6, 0))
        let transform = try #require(
            ModelPlacement.placedTransform(bounds: bounds, relativeTo: device)
        )
        // 1.2 m ahead and 25 cm below eye level.
        #expect(world(bounds.center, in: transform) ≈ SIMD3<Float>(0, 1.35, -1.2))
    }

    @Test func placeFacesTheModelAtTheViewer() throws {
        let yaw = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let device = Transform(rotation: yaw, translation: SIMD3<Float>(2, 1.6, 3))
        let bounds = BoundingBox(min: SIMD3<Float>(repeating: -0.5), max: SIMD3<Float>(repeating: 0.5))
        let transform = try #require(
            ModelPlacement.placedTransform(bounds: bounds, relativeTo: device)
        )

        let forward = ModelPlacement.viewerFrame(from: device).forward
        #expect(transform.rotation.act(SIMD3<Float>(0, 0, -1)) ≈ forward)
        let expectedCenter = device.translation + forward * 1.2 + SIMD3<Float>(0, -0.25, 0)
        #expect(world(bounds.center, in: transform) ≈ expectedCenter)
    }

    /// An empty or unloadable scene has no extent to scale, and dividing by it would produce an
    /// infinite scale. The caller leaves the entity where it is instead.
    @Test func placeDeclinesGeometryWithNoExtent() {
        let empty = BoundingBox(min: .zero, max: .zero)
        #expect(ModelPlacement.placedTransform(bounds: empty, relativeTo: nil) == nil)
    }

    // MARK: - Enter scale

    @Test func enterKeepsTheAuthoredScaleOfARoomSizedModel() {
        // A 20 x 6 x 15 m building: reach is ~12 m, comfortably inside both clamps.
        let bounds = BoundingBox(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(20, 6, 15))
        let reach = ModelPlacement.enteredReach(of: bounds)
        #expect((ModelPlacement.minimumEnteredModelReach...ModelPlacement.maximumEnteredModelReach).contains(reach))
        #expect(ModelPlacement.enteredScale(forReach: reach) == 1)
    }

    /// The regression that made Enter pointless for mechanical parts: a 20 cm bracket stayed 20 cm
    /// and sat two metres away inside an empty white sphere.
    @Test func enterScalesSmallGeometryUpToWalkThroughSize() {
        let bracket = BoundingBox(min: SIMD3<Float>(repeating: -0.1), max: SIMD3<Float>(repeating: 0.1))
        let scale = ModelPlacement.enteredScale(forReach: ModelPlacement.enteredReach(of: bracket))
        #expect(scale > 1)

        let scaledReach = ModelPlacement.enteredReach(of: bracket) * scale
        #expect(abs(scaledReach - ModelPlacement.minimumEnteredModelReach) < 1e-4)
    }

    @Test func enterScalesSiteSizedGeometryDownIntoTheBackdrop() {
        let site = BoundingBox(min: SIMD3<Float>(-500, 0, -500), max: SIMD3<Float>(500, 40, 500))
        let scale = ModelPlacement.enteredScale(forReach: ModelPlacement.enteredReach(of: site))
        #expect(scale < 1)

        let scaledReach = ModelPlacement.enteredReach(of: site) * scale
        #expect(abs(scaledReach - ModelPlacement.maximumEnteredModelReach) < 1e-3)
    }

    /// Degenerate geometry must not divide by zero and hand RealityKit an infinite scale.
    @Test func enterLeavesGeometryWithNoExtentAlone() {
        #expect(ModelPlacement.enteredScale(forReach: 0) == 1)
        let empty = BoundingBox(min: .zero, max: .zero)
        let transform = ModelPlacement.enteredTransform(bounds: empty, relativeTo: nil)
        #expect(transform.scale.x == 1)
        #expect(transform.scale.x.isFinite)
    }

    // MARK: - Enter placement

    @Test func enterStandsTheModelOnTheFloor() {
        let bounds = BoundingBox(min: SIMD3<Float>(-3, 2, -3), max: SIMD3<Float>(3, 8, 3))
        let transform = ModelPlacement.enteredTransform(bounds: bounds, relativeTo: nil)
        // Whatever the authored y offset, the lowest point of the model lands on y = 0.
        #expect(abs(world(bounds.min, in: transform).y) < 1e-4)
    }

    @Test func enterPutsTheNearestFaceTwoMetersAhead() {
        let bounds = BoundingBox(min: SIMD3<Float>(-10, 0, -20), max: SIMD3<Float>(10, 6, 0))
        let device = Transform(translation: SIMD3<Float>(0, 1.6, 0))
        let transform = ModelPlacement.enteredTransform(bounds: bounds, relativeTo: device)

        // The center of the face closest to the wearer, at floor level.
        let nearestFace = SIMD3<Float>(bounds.center.x, 0, bounds.max.z)
        let placed = world(nearestFace, in: transform)
        #expect(abs(placed.x) < 1e-4)
        #expect(abs(placed.z - -2) < 1e-4)
    }

    @Test func enterPlacesTheModelAlongTheViewerHeading() {
        let yaw = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        let device = Transform(rotation: yaw, translation: SIMD3<Float>(5, 1.6, 5))
        let bounds = BoundingBox(min: SIMD3<Float>(-10, 0, -20), max: SIMD3<Float>(10, 6, 0))
        let transform = ModelPlacement.enteredTransform(bounds: bounds, relativeTo: device)

        let forward = ModelPlacement.viewerFrame(from: device).forward
        let expected = device.translation + forward * 2
        let placed = world(SIMD3<Float>(bounds.center.x, 0, bounds.max.z), in: transform)
        // Turned around, so "two metres ahead" is now +Z. Height stays floor-relative.
        #expect(abs(placed.x - expected.x) < 1e-4)
        #expect(abs(placed.z - expected.z) < 1e-4)
        #expect(abs(placed.y) < 1e-4)
    }

    /// Enter's rotation is yaw-only, so a building never leans no matter how the wearer's head is
    /// tilted when the mode is entered.
    @Test func enterKeepsTheModelUpright() {
        let tilted = Transform(
            rotation: simd_quatf(angle: .pi / 5, axis: simd_normalize(SIMD3<Float>(1, 0.3, 0))),
            translation: SIMD3<Float>(0, 1.6, 0)
        )
        let bounds = BoundingBox(min: SIMD3<Float>(-5, 0, -5), max: SIMD3<Float>(5, 10, 5))
        let transform = ModelPlacement.enteredTransform(bounds: bounds, relativeTo: tilted)

        let up = transform.rotation.act(SIMD3<Float>(0, 1, 0))
        #expect(up ≈ SIMD3<Float>(0, 1, 0))
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
private func ≈ (lhs: SIMD3<Float>, rhs: SIMD3<Float>) -> Bool {
    simd_length(lhs - rhs) < 1e-4
}
