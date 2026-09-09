//
//  ModelStore.swift
//  DataExchangeViewer
//

import Foundation
import SwiftUI
import RealityKit
import simd

/// The one loaded model, shared by all three preview modes.
///
/// An entity has a single parent, and Portal, Volume, and Immersive are three separate scenes — so
/// the model is loaded once into this store and *re-parented* on a mode change rather than loaded
/// again per scene. For a several-hundred-megabyte BIM export the difference is the whole cost of
/// switching modes.
///
/// The store also owns everything derived from the file that the tools need and that only has to be
/// computed once: the unit correction, the explode axis and its rest transforms, the entry point,
/// and the model's bounds in meters.
@MainActor
@Observable
final class ModelStore {
    /// Something the model is missing or something the app couldn't do with it. Distinct from
    /// `loadError`: the model is on screen and usable, but a mode or a tool will be degraded, and
    /// silently degrading is how "explode does nothing" gets read as a broken build.
    enum Warning: String, CaseIterable, Identifiable, Sendable {
        /// The export has no named sub-assemblies — a flattened `Part_001…Part_n` dump. It renders
        /// correctly, but section box and explode have nothing meaningful to operate on.
        case flattenedHierarchy
        /// The stage's units couldn't be read, so a model authored in millimetres may appear at the
        /// wrong size in Immersive, where scale is the whole point.
        case unknownUnits

        var id: Self { self }
    }

    /// The entity the modes parent into their scene and transform. Never the loaded USDZ root —
    /// see the hierarchy comment in `load(url:name:)`.
    private(set) var root: Entity?

    /// Where tool affordances live: a child of `root`, sibling of `clipRoot`. Outside the clipped
    /// subtree on purpose, so the section box can't clip away its own drag handles.
    private(set) var toolOverlay: Entity?

    /// The model's own metric coordinate space, identity relative to `root`. The section box
    /// clips this and expresses its bounds in it, so `bounds` and the clipping bounds are directly
    /// comparable and a feather inset is in real model meters.
    private(set) var clipRoot: Entity?

    /// The scale correction applied to reach real meters, from `USDUnitScale`. Normally 1, because
    /// RealityKit's loader already honours the stage's `metersPerUnit`; kept as a stored value
    /// because the one case where it isn't 1 is the case that ruins Immersive.
    private(set) var unitScale: Float = 1

    /// The axis the explode tool separates along, chosen once at load from the model's own mass
    /// distribution. Y for the multi-storey case, which is most of them.
    private(set) var explodeAxis: SIMD3<Float> = [0, 1, 0]

    /// Where each exploding part sits when the tool is off, so deactivating restores exactly the
    /// pose the model loaded with rather than an accumulation of lerps.
    private(set) var restTransforms: [Entity: Transform] = [:]

    /// Full-explode displacement per part, in `assembly`'s coordinate space.
    private(set) var explodeOffsets: [Entity: SIMD3<Float>] = [:]

    /// The entity whose direct children the tools treat as parts: the first descendant with more
    /// than one child. `Entity(contentsOf:)` wraps the stage in a synthetic root, and an export
    /// typically nests one more named group inside that, so the interesting children are two or
    /// three levels down and "direct children of root" would be a single-element list.
    private(set) var assembly: Entity?

    /// The model's bounds in `root`'s space, in meters, with the unit correction applied.
    private(set) var bounds: BoundingBox = .empty

    /// Where Immersive stands the person: an authored `entryPoint` prim if the export has one, and
    /// the centre of the ground floor otherwise. In `root`'s space, in meters.
    private(set) var entryPoint: SIMD3<Float> = .zero

    /// Authored level-of-detail groups found in the export, if it has any. Empty for everything the
    /// conversion service produces today — see `LevelOfDetail`.
    private(set) var lodGroups: [LevelOfDetail.Group] = []

    private(set) var warnings: Set<Warning> = []
    private(set) var loadError: String?
    private(set) var isLoading = false

    /// The file currently loaded, so a repeated request for the same model is a no-op rather than
    /// a re-parse that also throws away the person's section box.
    private(set) var loadedURL: URL?

    /// Names accepted for the authored entry point, in preference order. A convention beats a
    /// centroid for any building with a front door, and costs the exporter one empty Xform.
    static let entryPointPrimNames = ["entryPoint", "EntryPoint", "entry_point"]

    /// Below this many children an "assembly" isn't one, and the tools have nothing to separate.
    private static let minimumSubassemblyCount = 2

    // MARK: - Loading

    /// Loads `url`, or returns immediately if it is already loaded.
    ///
    /// - Parameter name: the exchange's display name, used only for the entity's VoiceOver label.
    func load(url: URL, name: String) async {
        guard loadedURL != url else { return }

        reset()
        isLoading = true
        defer { isLoading = false }

        // Reading the stage's metadata and parsing its geometry are independent, and the metadata
        // read is file I/O that has no business on the main actor.
        let metadataTask = Task.detached(priority: .userInitiated) {
            try? USDStageMetadata.read(from: url)
        }

        let content: Entity
        do {
            content = try await USDzEntityCache.shared.entity(at: url)
        } catch {
            metadataTask.cancel()
            loadError = "Failed to load preview: \(error.localizedDescription)"
            return
        }

        let metadata = await metadataTask.value
        if metadata == nil {
            warnings.insert(.unknownUnits)
        }

        content.isAccessibilityElement = true
        content.accessibilityLabelKey = LocalizedStringResource("\(name)")

        // Four levels, each with exactly one job:
        //
        //   root      what a mode is free to transform (the portal fit, the volume fit, the
        //             immersive rig) — and where the whole-model collider and input target live
        //   clipRoot  identity, so its coordinate space *is* the model's own metric space; carries
        //             the section box's `ClippingComponent`. Separate from `root` because clipping
        //             applies to all of an entity's children, and the section box's own drag
        //             handles are children of `root` — on `root` the tool would clip its own
        //             affordances the moment someone dragged one inward
        //   unitRoot  the unit correction, applied exactly once
        //   content   the loader's baked transform: the stage's units and up-axis live here, so
        //             writing to it destroys them
        let unitRoot = Entity()
        unitRoot.name = "unitRoot"
        unitRoot.addChild(content)

        let clipRoot = Entity()
        clipRoot.name = "clipRoot"
        clipRoot.addChild(unitRoot)

        let toolOverlay = Entity()
        toolOverlay.name = "toolOverlay"

        let root = Entity()
        root.name = "modelRoot"
        root.addChild(clipRoot)
        root.addChild(toolOverlay)

        unitScale = USDUnitScale.residual(for: metadata, appliedRootScale: content.scale.x)
        unitRoot.scale = SIMD3<Float>(repeating: unitScale)

        self.clipRoot = clipRoot
        self.toolOverlay = toolOverlay
        bounds = content.visualBounds(relativeTo: root)
        assembly = Self.assemblyRoot(of: content)
        entryPoint = Self.resolveEntryPoint(in: content, relativeTo: root, bounds: bounds)

        if let assembly, Self.isFlattened(assembly) {
            warnings.insert(.flattenedHierarchy)
        }

        Self.configureInput(on: root, bounds: bounds)
        // Most of a building's interior is behind a wall from wherever the person is standing, and
        // occlusion culling is opt-in per entity. Set explicitly rather than relied on as a
        // default, so it survives someone reading this and wondering whether it's on.
        content.components.set(OcclusionCullingComponent(isEnabled: true))

        prepareExplode()
        lodGroups = LevelOfDetail.groups(in: content)

        self.root = root
        loadedURL = url
    }

    /// Drops the model. Called when the exchange changes or its conversion is cleared.
    func unload() {
        reset()
    }

    private func reset() {
        root?.removeFromParent()
        root = nil
        clipRoot = nil
        toolOverlay = nil
        owner = nil
        assembly = nil
        loadedURL = nil
        loadError = nil
        warnings = []
        restTransforms = [:]
        explodeOffsets = [:]
        explodeAxis = [0, 1, 0]
        lodGroups = []
        unitScale = 1
        bounds = .empty
        entryPoint = .zero
    }

    // MARK: - Scene ownership

    /// The mode whose scene currently holds the model, so a re-parent happens once per transition
    /// rather than on every `RealityView` update pass.
    private(set) var owner: PreviewMode?

    /// Parents the model into the active mode's scene, under `parent`.
    ///
    /// Called from every mode's `RealityView` update, which is what makes the exclusivity real: two
    /// scenes can be briefly alive during a transition, and both run on the main actor, so the last
    /// word belongs to whichever one matches the active mode. `addChild` re-parents, so the losing
    /// scene doesn't have to give the model up first.
    ///
    /// A parent entity rather than the `RealityViewContent` itself, because Portal needs the model
    /// *inside* the entity carrying `WorldComponent` — added to the scene root it would render in
    /// the room instead of through the portal.
    func attach(to parent: Entity, as mode: PreviewMode, activeMode: PreviewMode) {
        guard let root, mode == activeMode else { return }
        guard owner != mode || root.parent !== parent else { return }
        parent.addChild(root)
        owner = mode
    }

    /// Takes the model out of `mode`'s scene as that scene goes away. Ignored if another mode has
    /// already taken ownership, which is the normal case for a mode switch — the model is in its
    /// new scene by the time the old one disappears, and removing it then would blank the display.
    func detach(_ mode: PreviewMode) {
        guard owner == mode else { return }
        root?.removeFromParent()
        owner = nil
    }

    // MARK: - Explode

    /// Caches the rest pose and full-explode offset of every part. Runs once per load: the offsets
    /// are geometry, not state, and recomputing them mid-drag would make the parts jitter.
    private func prepareExplode() {
        restTransforms = [:]
        explodeOffsets = [:]
        guard let assembly else { return }

        // Only children that occupy space. An assembly's children routinely include things with no
        // geometry — an authored `entryPoint`, locators, empty groups — and giving those an offset
        // moves nothing while still consuming a slot and a gap in the layout, which spreads the
        // parts people *can* see further apart than they need to be.
        let children = assembly.children.filter {
            $0.visualBounds(relativeTo: assembly).extents != .zero
        }
        guard children.count >= Self.minimumSubassemblyCount else { return }

        let parts = children.map {
            ExplodeLayout.Part(bounds: $0.visualBounds(relativeTo: assembly))
        }
        explodeAxis = ExplodeLayout.axis(for: parts)
        let offsets = ExplodeLayout.offsets(for: parts, along: explodeAxis)

        for (child, offset) in zip(children, offsets) {
            restTransforms[child] = child.transform
            explodeOffsets[child] = offset
        }
    }

    /// Rebuilds the offsets from the rest pose in the model's metric coordinate frame.
    /// Convert offsets back to the assembly frame so authored rotation and units are respected.
    func setExplodeAxis(_ axis: ToolAxis) {
        resetExplode(animated: false)
        explodeAxis = axis.direction
        guard let assembly, let clipRoot else { return }
        let children = explodableParts
        let parts = children.map { ExplodeLayout.Part(bounds: $0.visualBounds(relativeTo: clipRoot)) }
        let offsets = ExplodeLayout.offsets(for: parts, along: axis.direction)
        for (child, offset) in zip(children, offsets) {
            explodeOffsets[child] = assembly.convert(direction: offset, from: clipRoot)
        }
    }

    /// The parts the explode tool moves, in a stable order.
    var explodableParts: [Entity] {
        assembly?.children.filter { explodeOffsets[$0] != nil } ?? []
    }

    /// Positions every part at `factor` of the way to its full-explode offset.
    ///
    /// A continuous factor rather than the one-shot `FromToBy` animation of Apple's sample: the
    /// tool is gesture-driven, so the model has to follow a drag in progress, which means setting
    /// positions per frame from a clamped scalar.
    func setExplodeFactor(_ factor: Float) {
        let t = min(max(factor, 0), 1)
        for (part, offset) in explodeOffsets {
            guard let rest = restTransforms[part] else { continue }
            part.position = rest.translation + offset * t
        }
    }

    /// Returns every part to its rest pose, optionally animated — which is what the tool does on
    /// deactivate, so parts settle back rather than snapping.
    func resetExplode(animated: Bool, duration: TimeInterval = 0.35) {
        for (part, rest) in restTransforms {
            if animated {
                part.move(to: rest, relativeTo: part.parent, duration: duration, timingFunction: .easeInOut)
            } else {
                part.transform = rest
            }
        }
    }

    // MARK: - Hierarchy inspection

    /// Descends through single-child wrappers to the first entity that actually branches.
    ///
    /// `Entity(contentsOf:)` returns a synthetic root holding the stage's default prim, which in
    /// turn usually holds one named group — so the sub-assemblies a person would recognise are
    /// several levels below the entity the loader hands back.
    static func assemblyRoot(of entity: Entity) -> Entity {
        var current = entity
        while current.children.count == 1, current.components[ModelComponent.self] == nil {
            current = current.children[0]
        }
        return current
    }

    /// Whether the export looks flattened: too few children to be an assembly, or children whose
    /// names are all machine-generated.
    ///
    /// A flattened model renders perfectly and is exactly as useless to these tools as an empty
    /// one, so it is worth saying out loud.
    static func isFlattened(_ assembly: Entity) -> Bool {
        let children = assembly.children.map { $0 }
        guard children.count >= minimumSubassemblyCount else { return true }

        let generated = children.filter { isGeneratedName($0.name) }.count
        return Float(generated) / Float(children.count) > 0.8
    }

    /// Matches the names conversion pipelines emit when they have no authored structure to carry
    /// over: `Part_001`, `Mesh12`, `node-3`, and an unnamed entity.
    static func isGeneratedName(_ name: String) -> Bool {
        if name.isEmpty { return true }
        let lowered = name.lowercased()
        for prefix in ["part", "mesh", "node", "object", "group", "geom", "shape"] {
            guard lowered.hasPrefix(prefix) else { continue }
            let suffix = lowered.dropFirst(prefix.count).drop { $0 == "_" || $0 == "-" || $0 == " " }
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// The authored entry point if the export has one, and the ground-floor centroid otherwise.
    static func resolveEntryPoint(
        in content: Entity,
        relativeTo root: Entity,
        bounds: BoundingBox
    ) -> SIMD3<Float> {
        for name in entryPointPrimNames {
            if let prim = content.findEntity(named: name) {
                return prim.position(relativeTo: root)
            }
        }
        return ModelPlacement.groundFloorEntryPoint(bounds: bounds)
    }

    // MARK: - Input

    /// Gives the model root a collision shape and an input target, so gestures can reach it.
    ///
    /// One box around the whole model, not a generated shape per mesh. The entities that take input
    /// in this build are the model as a whole and the section box's own handles; per-part selection
    /// is a separate feature. `generateCollisionShapes(recursive:)` on a BIM assembly would build
    /// thousands of convex hulls on the main actor at load, to serve gestures that only ever hit
    /// the outside of the model.
    static func configureInput(on root: Entity, bounds: BoundingBox) {
        let extents = bounds.extents
        guard extents.x > 0, extents.y > 0, extents.z > 0 else { return }

        let shape = ShapeResource
            .generateBox(size: extents)
            .offsetBy(translation: bounds.center)
        root.components.set(CollisionComponent(shapes: [shape], mode: .trigger))
        root.components.set(InputTargetComponent())
    }
}
