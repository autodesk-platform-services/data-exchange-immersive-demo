//
//  PortalScene.swift
//  DataExchangeViewer
//

import Foundation
import RealityKit
import simd

/// Owns the RealityKit entities behind Portal mode.
///
/// Deliberately not `@State` default values on the preview view: a `@State` initial value is
/// evaluated on every initialization of the view struct — and SwiftUI re-creates that struct on
/// every parent invalidation — so a plane mesh, a `PortalMaterial`, and an environment probe would
/// be allocated and immediately discarded on each pass. Building them from `RealityView`'s `make:`
/// closure through this holder means the GPU resources are created exactly once.
@MainActor
final class PortalScene {
    private var root: Entity?
    /// Carries `WorldComponent`: everything under it renders through the portal rather than in the
    /// room. The model, the backdrop, and the image-based light all live here.
    private var world: Entity?
    /// Where `ModelStore` parents the model.
    private(set) var modelContainer: Entity?
    /// The portal surface itself, exposed so the view can target a tap gesture at it.
    private(set) var portalPlane: ModelEntity?

    /// The portal size the layout most recently asked for, and the size the current plane mesh was
    /// generated for. They differ only between a resize request and the scene being ready.
    private var requestedSize: SIMD2<Float>?
    private var meshSize: SIMD2<Float>?

    private var buildTask: Task<Entity, Never>?

    /// Why the portal has no image-based lighting, when it doesn't. Retained rather than discarded:
    /// without an environment a PBR model inside a near-black world renders as a silhouette, which
    /// looks like a broken model rather than missing lighting. Kept after `build` finishes because
    /// the scene is built once and re-shown, so every `makeRoot` can report it.
    private(set) var lightingFailure: Error?

    /// The root to add to the scene, built on first call and reused afterwards. Portal is torn down
    /// and re-shown whenever another mode takes over, and rebuilding the portal and its environment
    /// probe each time is wasted work.
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
        world.name = "portalWorld"
        let modelContainer = Entity()
        modelContainer.name = "portalModelContainer"
        let portalPlane = ModelEntity(
            mesh: .generatePlane(width: 1, height: 1),
            materials: [PortalMaterial()]
        )
        portalPlane.name = "portalPlane"

        world.components.set(WorldComponent())
        world.addChild(modelContainer)
        world.addChild(PreviewEnvironment.makeBackdrop(radius: PreviewEnvironment.portalBackdropRadius))
        root.addChild(world)

        do {
            PreviewEnvironment.applyLighting(try await PreviewEnvironment.makeEnvironment(), to: world)
        } catch {
            lightingFailure = error
        }

        // A portal is otherwise read-only, so the plane needs a collider and an input target for
        // the one gesture it does accept: a tap, to promote the model into Volume mode.
        portalPlane.components.set(InputTargetComponent())
        portalPlane.components.set(HoverEffectComponent())
        root.addChild(portalPlane)

        self.root = root
        self.world = world
        self.modelContainer = modelContainer
        self.portalPlane = portalPlane
        self.buildTask = nil
        applyPortalSize()
        return root
    }

    /// Resizes the portal opening, and with it the volume the world is clipped to.
    func resizePortal(width: Float, height: Float) {
        requestedSize = SIMD2<Float>(width, height)
        applyPortalSize()
    }

    /// Regenerating the plane mesh is the expensive part of an update pass, and `update:` re-runs on
    /// any observed change — including every `AppModel` mutation — so the work is skipped unless the
    /// requested size differs from what the current mesh was generated for.
    private func applyPortalSize() {
        guard let portalPlane, let world, let requestedSize, requestedSize != meshSize else { return }
        meshSize = requestedSize

        portalPlane.model?.mesh = .generatePlane(
            width: requestedSize.x,
            height: requestedSize.y,
            cornerRadius: 0.02
        )
        portalPlane.components.set(CollisionComponent(
            shapes: [.generateBox(size: SIMD3<Float>(requestedSize.x, requestedSize.y, 0.01))],
            mode: .trigger
        ))

        // Clip the world to a box rather than to a single plane. `clippingPlane` cuts everything
        // in front of one plane, which leaves the world's contents free to spread out sideways
        // beyond the opening; a volume confines them to the frame the model was fitted into, so
        // nothing can appear beside the portal.
        var portal = PortalComponent(target: world)
        portal.clippingMode = .volume(ModelPlacement.portalClippingVolume(
            width: requestedSize.x,
            height: requestedSize.y
        ))
        // Nobody walks through this portal — it is inside a flat window on a desk.
        portal.crossingMode = .disabled
        portalPlane.components.set(portal)
    }
}
