//
//  ModelStoreTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
import RealityKit
import simd
@testable import DataExchangeViewer

/// The load pipeline end to end, against a generated USD stage.
///
/// A real load rather than hand-built entities, because most of what `ModelStore` derives — the
/// unit correction, the assembly root, the bounds in meters, the explode cache — depends on what
/// RealityKit's loader actually produces, and hand-built entities would only test the arithmetic
/// that `ModelPlacementTests` and `ExplodeLayoutTests` already cover.
/// Serialized: `USDzEntityCache` holds one slot and cancels an in-flight parse when a *different*
/// file is asked for. That is correct for the app — one exchange is previewed at a time — but it
/// means two of these loading different files in parallel would cancel each other.
@MainActor
@Suite("Model store", .serialized)
struct ModelStoreTests {
    /// A four-storey building in millimetres: 40 m × 20 m slabs stacked 3.5 m apart, with an
    /// authored entry point. Millimetres on purpose — the unit path is the one that only shows up
    /// at 1:1.
    private func buildingUSDA() -> String {
        var storeys = ""
        for level in 0..<4 {
            let z = Double(level) * 3500 + 100
            storeys += """

                def Xform "Level_0\(level + 1)"
                {
                    double3 xformOp:translate = (0, \(z), 0)
                    uniform token[] xformOpOrder = ["xformOp:translate"]

                    def Mesh "Slab"
                    {
                        int[] faceVertexCounts = [4]
                        int[] faceVertexIndices = [0, 1, 2, 3]
                        point3f[] points = [
                            (-20000, 0, -10000), (20000, 0, -10000),
                            (20000, 0, 10000), (-20000, 0, 10000)
                        ]
                    }
                }
            """
        }

        return """
        #usda 1.0
        (
            defaultPrim = "Building"
            metersPerUnit = 0.001
            upAxis = "Y"
        )

        def Xform "Building"
        {
        \(storeys)

            def Xform "entryPoint"
            {
                double3 xformOp:translate = (-20000, 100, 0)
                uniform token[] xformOpOrder = ["xformOp:translate"]
            }
        }
        """
    }

    private func load(_ usda: String) async throws -> (ModelStore, URL) {
        let url = URL.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).usda")
        try usda.write(to: url, atomically: true, encoding: .utf8)
        let store = ModelStore()
        await store.load(url: url, name: "Test Building")
        return (store, url)
    }

    @Test func loadsAndReportsNoError() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(store.loadError == nil, "\(store.loadError ?? "")")
        #expect(store.root != nil)
        #expect(store.clipRoot != nil)
        #expect(store.toolOverlay != nil)
        #expect(store.loadedURL == url)
    }

    /// The loader already applied the millimetre conversion, so there is nothing left to correct —
    /// and the bounds the modes work from are in real meters.
    @Test func normalisesToMetersWithoutDoubleScaling() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(store.unitScale == 1)
        let extents = store.bounds.extents
        #expect(abs(extents.x - 40) < 0.01, "40 m wide, got \(extents.x)")
        #expect(abs(extents.z - 20) < 0.01, "20 m deep, got \(extents.z)")
        // Four slabs 3.5 m apart: 10.5 m from the first to the last.
        #expect(abs(extents.y - 10.5) < 0.01, "10.5 m of storeys, got \(extents.y)")
    }

    /// The `clipRoot` level exists so the section box's bounds and the model's bounds are directly
    /// comparable, which only holds if it is identity relative to `root`.
    @Test func clipRootIsIdentityRelativeToTheModelRoot() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        let clipRoot = try #require(store.clipRoot)
        let root = try #require(store.root)
        #expect(clipRoot.transformMatrix(relativeTo: root) == matrix_identity_float4x4)
    }

    /// The tool overlay must be outside the clipped subtree, or the section box clips away its own
    /// drag handles the moment someone pulls one inward.
    @Test func toolOverlayIsNotInsideTheClippedSubtree() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        let overlay = try #require(store.toolOverlay)
        let clipRoot = try #require(store.clipRoot)
        #expect(overlay.parent === store.root)
        #expect(overlay.parent !== clipRoot)
    }

    @Test func findsTheStoreysAsExplodableParts() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        // Four storeys. The authored entry point is a fifth child, and is deliberately *not* one:
        // it occupies no space, so exploding it would move nothing while still spacing the storeys
        // that far apart.
        #expect(store.explodableParts.count == 4)
        #expect(store.explodeAxis ≈ SIMD3<Float>(0, 1, 0), "a storey stack explodes vertically")
    }

    @Test func usesTheAuthoredEntryPoint() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        // −20000 mm on x, 100 mm up: the middle of one long edge at ground level.
        #expect(store.entryPoint ≈ SIMD3<Float>(-20, 0.1, 0))
    }

    @Test func aFullExplodeSeparatesTheStoreysAndReturningRestoresThem() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        let parts = store.explodableParts
        let rest = parts.map(\.position)

        store.setExplodeFactor(1)
        let exploded = parts.map(\.position)
        #expect(zip(rest, exploded).contains { simd_length($0 - $1) > 0.01 })

        store.resetExplode(animated: false)
        for (part, original) in zip(parts, rest) {
            #expect(part.position ≈ original)
        }
    }

    /// A factor is a fraction of the way there, not a switch — this is what a drag in progress
    /// depends on.
    @Test func explodeFactorInterpolates() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        let part = try #require(store.explodableParts.max { partHeight($0) < partHeight($1) })
        store.resetExplode(animated: false)
        let rest = part.position

        store.setExplodeFactor(1)
        let full = part.position - rest
        store.setExplodeFactor(0.5)
        let half = part.position - rest

        #expect(simd_length(full) > 0.01, "the topmost storey should move at all")
        #expect(simd_length(half - full / 2) < 1e-3)
    }

    @Test func clampsTheExplodeFactorToItsRange() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        let part = try #require(store.explodableParts.first)
        store.setExplodeFactor(1)
        let atOne = part.position
        store.setExplodeFactor(5)
        #expect(part.position ≈ atOne)

        store.setExplodeFactor(0)
        let atZero = part.position
        store.setExplodeFactor(-3)
        #expect(part.position ≈ atZero)
    }

    /// A flattened export renders correctly and leaves both tools with nothing to operate on, which
    /// is worth saying out loud rather than presenting tools that visibly do nothing.
    @Test func warnsAboutAFlattenedExport() async throws {
        var parts = ""
        for index in 1...12 {
            parts += """

                def Mesh "Part_\(String(format: "%03d", index))"
                {
                    int[] faceVertexCounts = [3]
                    int[] faceVertexIndices = [0, 1, 2]
                    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, \(index))]
                }
            """
        }
        let (store, url) = try await load("""
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Root"
        {
        \(parts)
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(store.warnings.contains(.flattenedHierarchy))
    }

    @Test func doesNotWarnAboutAProperlyStructuredExport() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(store.warnings.isEmpty)
    }

    @Test func reportsAFailureForAFileThatIsNotAModel() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).usda")
        try "not a stage".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ModelStore()
        await store.load(url: url, name: "Broken")

        #expect(store.loadError != nil)
        #expect(store.root == nil)
        #expect(store.loadedURL == nil)
    }

    @Test func unloadingClearsEverythingDerived() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        store.unload()

        #expect(store.root == nil)
        #expect(store.clipRoot == nil)
        #expect(store.loadedURL == nil)
        #expect(store.explodableParts.isEmpty)
        #expect(store.bounds.extents == .zero)
        #expect(store.warnings.isEmpty)
    }

    /// Scene ownership: the active mode takes the model, and only the mode that currently holds it
    /// can give it up. Otherwise a mode switch's old scene disappearing would blank the new one.
    @Test func onlyTheOwningModeCanDetachTheModel() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        let volumeParent = Entity()
        store.attach(to: volumeParent, as: .volume, activeMode: .volume)
        #expect(store.owner == .volume)
        #expect(store.root?.parent === volumeParent)

        // Portal's scene going away must not take the model out of the volume.
        store.detach(.portal)
        #expect(store.owner == .volume)
        #expect(store.root?.parent === volumeParent)

        store.detach(.volume)
        #expect(store.owner == nil)
        #expect(store.root?.parent == nil)
    }

    @Test func aModeThatIsNotActiveDoesNotTakeTheModel() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }

        let portalParent = Entity()
        store.attach(to: portalParent, as: .portal, activeMode: .immersive)
        #expect(store.owner == nil)
        #expect(store.root?.parent == nil)
    }

    @Test func chosenExplodeAxesRespectAuthoredRotationAndScale() async throws {
        let (store, url) = try await load(buildingUSDA())
        defer { try? FileManager.default.removeItem(at: url) }
        let assembly = try #require(store.assembly)
        let clipRoot = try #require(store.clipRoot)
        assembly.orientation = simd_quatf(angle: .pi / 3, axis: [0, 0, 1])
        assembly.scale *= 2
        let tool = ExplodeTool()
        tool.bind(to: store)
        #expect(tool.activate())
        for axis in ToolAxis.allCases {
            tool.setAxis(axis)
            let starts = store.explodableParts.map { $0.position(relativeTo: clipRoot) }
            tool.beginDrag()
            tool.updateDrag(displacement: axis.direction * store.bounds.extents[axis.index] * ExplodeTool.travelFraction)
            #expect(abs(tool.factor - 1) < 0.0001)
            let deltas = zip(store.explodableParts, starts).map { $0.position(relativeTo: clipRoot) - $1 }
            #expect(deltas.contains { simd_length($0) > 0.001 })
            for delta in deltas {
                for other in ToolAxis.allCases where other != axis {
                    #expect(abs(delta[other.index]) < 0.001)
                }
            }
        }
        tool.deactivate()
        for part in store.explodableParts {
            #expect(part.transform == store.restTransforms[part])
        }
    }

    private func partHeight(_ entity: Entity) -> Float {
        entity.position.y
    }
}

/// The section box's state machine and the cache that makes turning it off non-destructive.
@MainActor
@Suite("Section box tool")
struct SectionBoxToolTests {
    private let modelBounds = BoundingBox(
        min: SIMD3<Float>(-10, 0, -20),
        max: SIMD3<Float>(30, 24, 20)
    )
    private let key = URL(fileURLWithPath: "/tmp/section-tool-test.usdz")

    /// The tool holds its clipped entity weakly — it does not own the model — so the hierarchy has
    /// to be returned alongside it and kept alive for the length of the test.
    private func makeTool() -> (tool: SectionBoxTool, root: Entity) {
        let tool = SectionBoxTool(cache: ClippingBoundsCache())
        let root = Entity()
        let clipRoot = Entity()
        let overlay = Entity()
        root.addChild(clipRoot)
        root.addChild(overlay)
        tool.bind(clipRoot: clipRoot, handleRoot: overlay, modelBounds: modelBounds, key: key)
        return (tool, root)
    }

    @Test func startsOffAtTheModelsFullExtent() {
        let (tool, root) = makeTool()
        defer { _ = root }
        #expect(tool.state == .off)
        #expect(tool.bounds.min ≈ modelBounds.min)
        #expect(tool.bounds.max ≈ modelBounds.max)
    }

    /// Three states, not two: hiding the handles is a separate step from switching the cut off,
    /// because a section someone has set up is worth looking at without its affordances on top.
    @Test func cyclesThroughItsThreeStates() {
        let (tool, root) = makeTool()
        defer { _ = root }
        tool.activate()
        #expect(tool.state == .editing)

        tool.toggleEditing()
        #expect(tool.state == .on)

        tool.toggleEditing()
        #expect(tool.state == .editing)

        tool.deactivate()
        #expect(tool.state == .off)

        tool.toggleEditing()
        #expect(tool.state == .editing, "toggling from off re-activates")
    }

    /// The behaviour the cache exists for: someone who cuts down to one storey, switches the tool
    /// off to see the whole building, and switches it back on has not asked to lose their section.
    @Test func retainsTheSectionAcrossDeactivation() {
        let (tool, root) = makeTool()
        defer { _ = root }
        tool.activate()

        let face = SectionBoxGeometry.Face.maxY
        tool.beginDrag(face: face)
        tool.updateDrag(displacement: SIMD3<Float>(0, -18, 0))
        tool.endDrag()
        let cut = tool.bounds

        tool.deactivate()
        tool.activate()

        #expect(tool.bounds.max ≈ cut.max)
        #expect(tool.bounds.min ≈ cut.min)
    }

    @Test func resetReturnsToTheFullExtentWithoutLeavingTheTool() {
        let (tool, root) = makeTool()
        defer { _ = root }
        tool.activate()
        tool.beginDrag(face: .minX)
        tool.updateDrag(displacement: SIMD3<Float>(12, 0, 0))
        tool.endDrag()
        #expect(tool.bounds.min.x > modelBounds.min.x)

        tool.reset()
        #expect(tool.bounds.min ≈ modelBounds.min)
        #expect(tool.state == .editing)
    }

    /// A drag with no face begun is a drag on something else — the model, or nothing — and must not
    /// move the box.
    @Test func ignoresADragThatDidNotBeginOnAFace() {
        let (tool, root) = makeTool()
        defer { _ = root }
        tool.activate()
        let before = tool.bounds
        tool.updateDrag(displacement: SIMD3<Float>(0, -10, 0))
        #expect(tool.bounds.max ≈ before.max)
    }
}

/// The explode tool's activation contract and its drag-to-factor mapping.
@MainActor
@Suite("Explode tool")
struct ExplodeToolTests {
    @Test func refusesToActivateWithNothingToSeparate() {
        let tool = ExplodeTool()
        tool.bind(to: ModelStore())
        #expect(!tool.activate(), "an unloaded store has no parts")
        #expect(!tool.isActive)
    }

    @Test func aFactorSetWhileInactiveIsIgnored() {
        let tool = ExplodeTool()
        tool.bind(to: ModelStore())
        tool.setFactor(0.8)
        #expect(tool.factor == 0)
    }
}
