//
//  PortalScene.swift
//  DataExchangeViewer
//

import RealityKit
import simd

/// Owns the RealityKit entities behind the Peek portal.
///
/// These used to be `@State` default values on `USDzPreviewView`. A `@State` initial value is
/// evaluated on every initialization of the view struct — and SwiftUI re-creates that struct on
/// every parent invalidation — so a plane mesh and a `PortalMaterial` were being allocated and
/// immediately discarded on each pass. Building them from `RealityView`'s `make:` closure through
/// this holder means the GPU resources are created exactly once.
final class PortalScene {
    private var root: Entity?
    private var modelContainer: Entity?
    private var portalPlane: ModelEntity?
    /// The portal size the layout most recently asked for, and the size the current plane mesh
    /// was generated for. They differ only between a resize request and the scene being ready.
    private var requestedSize: SIMD2<Float>?
    private var meshSize: SIMD2<Float>?
    /// The model to show. Held here because building the scene and loading the file run
    /// concurrently, and either can finish first.
    private var model: Entity?
    private var buildTask: Task<Entity, Never>?

    /// Why the portal has no image-based lighting, when it doesn't. Retained rather than
    /// discarded: without the studio environment a PBR model renders effectively unlit, which
    /// looks like a broken model rather than missing lighting. Kept after `build` finishes
    /// because the scene is built once and re-shown, so every `makeRoot` can report it.
    private(set) var lightingFailure: Error?

    /// The root to add to the scene, built on first call and reused afterwards. Peek is torn down
    /// and re-shown whenever the immersive space opens and closes, and rebuilding the portal and
    /// its environment probe each time is wasted work.
    func makeRoot() async -> Entity {
        if let root { return root }
        if let buildTask { return await buildTask.value }

        let task = Task { await build() }
        buildTask = task
        return await task.value
    }

    private func build() async -> Entity {
        let root = Entity()
        let world = Entity()
        let modelContainer = Entity()
        let portalPlane = ModelEntity(
            mesh: .generatePlane(width: 1, height: 1),
            materials: [PortalMaterial()]
        )

        world.components.set(WorldComponent())
        world.addChild(modelContainer)
        root.addChild(world)

        do {
            StudioLighting.apply(try await StudioLighting.makeEnvironment(), to: world)
        } catch {
            lightingFailure = error
        }

        portalPlane.components.set(PortalComponent(target: world))
        root.addChild(portalPlane)

        self.root = root
        self.modelContainer = modelContainer
        self.portalPlane = portalPlane
        self.buildTask = nil
        // Pick up anything that arrived while the scene was still being built.
        if let model {
            modelContainer.addChild(model)
        }
        applyPortalSize()
        return root
    }

    /// Swaps the previewed model. Only the model container is touched, so the lighting and
    /// backdrop entities that live alongside it under the portal world stay in place.
    func setModel(_ entity: Entity?) {
        model = entity
        // Nothing to attach it to yet; `build` picks it up when it finishes.
        guard let modelContainer else { return }
        modelContainer.children.removeAll()
        if let entity {
            modelContainer.addChild(entity)
        }
    }

    /// Resizes the portal opening.
    func resizePortal(width: Float, height: Float) {
        requestedSize = SIMD2<Float>(width, height)
        applyPortalSize()
    }

    /// Regenerating the plane mesh is the expensive part of an update pass, and `update:` re-runs
    /// on any observed change — including every `AppModel` mutation — so the work is skipped
    /// unless the requested size differs from what the current mesh was generated for.
    private func applyPortalSize() {
        guard let portalPlane, let requestedSize, requestedSize != meshSize else { return }
        meshSize = requestedSize
        portalPlane.model?.mesh = .generatePlane(
            width: requestedSize.x,
            height: requestedSize.y,
            cornerRadius: 0.02
        )
    }
}
