import Testing
import RealityKit
import simd
@testable import DataExchangeViewer

@MainActor
@Suite("Volume tools")
struct VolumeToolTests {
    private let bounds = BoundingBox(min: [-2, -3, -4], max: [2, 3, 4])

    @Test func toolbarOffersAllFourTools() {
        #expect(ActiveTool.selectable == [.plane, .section, .explode, .measure])
    }

    @Test(arguments: ToolAxis.allCases) func planeCutsOnlyTheSelectedAxis(axis: ToolAxis) {
        for flipped in [false, true] {
            let cut = PlaneClippingTool.clippingBounds(model: bounds, axis: axis, fraction: 0.5, flipped: flipped)
            #expect((flipped ? cut.min[axis.index] : cut.max[axis.index]) == 0)
            for other in ToolAxis.allCases where other != axis {
                #expect(cut.min[other.index] < bounds.min[other.index])
                #expect(cut.max[other.index] > bounds.max[other.index])
            }
        }
    }

    @Test func planeDragIsAbsoluteAndHidingKeepsTheCut() {
        let root = Entity()
        let overlay = Entity()
        let plane = PlaneClippingTool()
        plane.bind(clipRoot: root, overlay: overlay, bounds: bounds)
        plane.activate()
        plane.beginDrag()
        plane.updateDrag(displacement: [99, 1.5, 99])
        plane.updateDrag(displacement: [99, 1.5, 99])
        #expect(plane.fraction == 0.75)
        plane.toggleHandle()
        #expect(root.components[ClippingComponent.self] != nil)
        #expect(overlay.children.allSatisfy { !$0.isEnabled })
        plane.deactivate()
        #expect(root.components[ClippingComponent.self] == nil)
    }

    @Test func boxDoesNotHideOtherToolsOverlay() {
        let root = Entity()
        let overlay = Entity()
        let otherTool = Entity()
        overlay.addChild(otherTool)
        let box = SectionBoxTool(cache: ClippingBoundsCache())
        box.bind(clipRoot: root, handleRoot: overlay, modelBounds: bounds, key: nil)
        box.activate()
        box.deactivate()
        #expect(overlay.isEnabled)
        #expect(otherTool.isEnabled)
    }

    @Test func clippingHandlesRemainReachableInsideTheModel() {
        let root = Entity()
        let clip = Entity()
        let overlay = Entity()
        root.addChild(clip)
        root.addChild(overlay)
        ModelStore.configureInput(on: root, bounds: bounds)
        ModelStore.configureInput(on: clip, bounds: bounds)
        let original = root.components[CollisionComponent.self]
        let plane = PlaneClippingTool()
        plane.bind(clipRoot: clip, overlay: overlay, bounds: bounds)
        plane.activate()
        let input = ModelCollisionOverride()
        input.suspend(root: root, clipRoot: clip)
        #expect(root.components[CollisionComponent.self] == nil)
        #expect(clip.components[CollisionComponent.self] == nil)
        #expect(overlay.children.contains { $0.isEnabled && $0.components[CollisionComponent.self] != nil })
        input.restore()
        #expect(root.components[CollisionComponent.self] == original)
        #expect(clip.components[CollisionComponent.self] != nil)
    }

    @Test func measurementStaysInModelMetersAndThirdPointStartsAgain() throws {
        let root = Entity()
        let clip = Entity()
        let overlay = Entity()
        root.addChild(clip)
        root.addChild(overlay)
        let measure = MeasureTool()
        measure.bind(root: root, clipRoot: clip, overlay: overlay, bounds: bounds)
        measure.activate()
        measure.addPoint([0, 0, 0])
        measure.addPoint([3, 4, 0])
        root.scale = [0.02, 0.02, 0.02]
        #expect(try #require(measure.distance) == 5)
        measure.addPoint([1, 2, 3])
        #expect(measure.points == [[1, 2, 3]])
        #expect(measure.distance == nil)
        measure.deactivate()
        #expect(measure.points.isEmpty)
        #expect(overlay.children.allSatisfy { $0.children.isEmpty })
    }

    @Test func surfaceSelectionRestoresOriginalCollisionAndInput() async throws {
        let root = Entity()
        let clip = Entity()
        let overlay = Entity()
        let mesh = ModelEntity(mesh: .generateBox(size: 1))
        root.addChild(clip)
        root.addChild(overlay)
        clip.addChild(mesh)
        ModelStore.configureInput(on: clip, bounds: bounds)
        let authoredCollision = clip.components[CollisionComponent.self]
        ModelStore.configureInput(on: root, bounds: bounds)
        let original = root.components[CollisionComponent.self]
        let measure = MeasureTool()
        measure.bind(root: root, clipRoot: clip, overlay: overlay, bounds: bounds)
        measure.activate()
        await measure.prepare()
        #expect(measure.error == nil)
        #expect(root.components[CollisionComponent.self] == nil)
        #expect(measure.accepts(mesh))
        #expect(clip.components[CollisionComponent.self] == nil)
        #expect(!measure.accepts(root))
        #expect(mesh.components[CollisionComponent.self] != nil)
        measure.deactivate()
        #expect(root.components[CollisionComponent.self] == original)
        #expect(clip.components[CollisionComponent.self] == authoredCollision)
        #expect(mesh.components[CollisionComponent.self] == nil)
        #expect(mesh.components[InputTargetComponent.self] == nil)
        measure.activate()
        await measure.prepare()
        #expect(measure.accepts(mesh))
        measure.deactivate()
    }
}
