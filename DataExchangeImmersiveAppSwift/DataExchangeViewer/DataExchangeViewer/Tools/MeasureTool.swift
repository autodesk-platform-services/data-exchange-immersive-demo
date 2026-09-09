import SwiftUI
import RealityKit
import simd

/// Surface selection uses triangle colliders, never the whole-model bounding box or convex hulls.
/// Points live in clipRoot's meter space so fitting/resizing the volume cannot change the result.
@MainActor
@Observable
final class MeasureTool {
    private(set) var isActive = false
    private(set) var isPreparing = false
    private(set) var error: String?
    private(set) var points: [SIMD3<Float>] = []
    var distance: Float? { points.count == 2 ? simd_distance(points[0], points[1]) : nil }

    private weak var root: Entity?
    private weak var clipRoot: Entity?
    private let markers = Entity()
    private var radius: Float = 0.005
    private let collisionOverride = ModelCollisionOverride()
    private var generation = UUID()
    private struct Surface {
        let entity: Entity
        let shape: ShapeResource
        let collision: CollisionComponent?
        let input: InputTargetComponent?
    }
    private var surfaces: [Surface] = []

    func bind(root: Entity, clipRoot: Entity, overlay: Entity, bounds: BoundingBox) {
        deactivate()
        markers.removeFromParent()
        surfaces = []
        self.root = root
        self.clipRoot = clipRoot
        radius = max(simd_length(bounds.extents) * 0.004, 0.0001)
        overlay.addChild(markers)
    }

    func activate() { isActive = true; error = nil; clear() }

    func prepare() async {
        guard isActive, let root, let clipRoot else { return }
        let token = UUID()
        generation = token
        isPreparing = true
        defer { if generation == token { isPreparing = false } }
        // Removing the coarse collider also prevents false picks while surfaces are prepared.
        collisionOverride.suspend(root: root, clipRoot: clipRoot)
        if surfaces.isEmpty {
            var pending: [Surface] = []
            var queue = [clipRoot]
            do {
                while let entity = queue.popLast() {
                    try Task.checkCancellation()
                    queue.append(contentsOf: entity.children)
                    guard let model = entity.components[ModelComponent.self] else { continue }
                    let shape = try await ShapeResource.generateStaticMesh(from: model.mesh)
                    guard isActive, generation == token else { return }
                    pending.append(Surface(entity: entity, shape: shape,
                        collision: entity.components[CollisionComponent.self],
                        input: entity.components[InputTargetComponent.self]))
                }
                guard !Task.isCancelled, isActive, generation == token else { return }
                surfaces = pending
            } catch {
                guard isActive, generation == token, !Task.isCancelled else { return }
                self.error = "Could not prepare design surfaces for measurement. Select Measure again to retry."
                return
            }
        }
        guard isActive, generation == token, !Task.isCancelled else { return }
        for surface in surfaces {
            surface.entity.components.set(CollisionComponent(shapes: [surface.shape], mode: .trigger))
            surface.entity.components.set(InputTargetComponent())
        }
        if surfaces.isEmpty { error = "This design has no measurable surfaces." }
    }

    func deactivate() {
        generation = UUID()
        if isActive {
            for surface in surfaces {
                if let collision = surface.collision { surface.entity.components.set(collision) }
                else { surface.entity.components.remove(CollisionComponent.self) }
                if let input = surface.input { surface.entity.components.set(input) }
                else { surface.entity.components.remove(InputTargetComponent.self) }
            }
        }
        collisionOverride.restore()
        isActive = false
        isPreparing = false
        clear()
    }

    func accepts(_ entity: Entity) -> Bool {
        isActive && !isPreparing && error == nil && surfaces.contains { $0.entity === entity }
    }

    func addPoint(_ point: SIMD3<Float>) {
        guard isActive, point.x.isFinite, point.y.isFinite, point.z.isFinite else { return }
        if points.count == 2 { clear() }
        points.append(point)
        let marker = ModelEntity(mesh: .generateSphere(radius: radius), materials: [UnlitMaterial(color: .yellow)])
        marker.position = point
        markers.addChild(marker)
        if points.count == 2 {
            let delta = points[1] - points[0]
            let length = simd_length(delta)
            guard length > 0 else { return }
            let line = ModelEntity(mesh: .generateBox(size: [radius * 0.4, radius * 0.4, length]),
                                   materials: [UnlitMaterial(color: .yellow)])
            line.position = (points[0] + points[1]) / 2
            line.orientation = SectionBoxGeometry.rotation(from: [0, 0, 1], to: delta / length)
            markers.addChild(line)
        }
    }

    func clear() {
        points = []
        for child in Array(markers.children) { child.removeFromParent() }
    }
}
