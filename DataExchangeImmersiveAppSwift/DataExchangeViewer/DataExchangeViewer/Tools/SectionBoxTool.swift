//
//  SectionBoxTool.swift
//  DataExchangeViewer
//

import Foundation
import SwiftUI
import RealityKit
import simd

/// Cuts the model with a draggable box, using `ClippingComponent`.
///
/// Three states rather than two, following Apple's Model Manipulator sample: a section someone has
/// set up is worth keeping while they look at the result, so hiding the handles is a separate step
/// from switching the section off.
@MainActor
@Observable
final class SectionBoxTool {
    enum State: String, Sendable {
        /// No clipping. The bounds are still remembered — see `ClippingBoundsCache`.
        case off
        /// Clipped, handles hidden: the state for actually looking at the section.
        case on
        /// Clipped, six face handles visible and draggable.
        case editing
    }

    private(set) var state: State = .off

    /// The section, in the model's own metric space (`ModelStore.clipRoot`).
    private(set) var bounds: BoundingBox = .empty

    /// The entity being clipped, and the coordinate space `bounds` is expressed in.
    private weak var clipRoot: Entity?
    /// Parent of the six handles. A sibling of `clipRoot`, so the tool doesn't clip its own
    /// affordances out of existence as the box shrinks.
    private var handleRoot: Entity?
    private var handles: [SectionBoxGeometry.Face: ModelEntity] = [:]

    private var modelBounds: BoundingBox = .empty
    private let cache: ClippingBoundsCache
    private var modelKey: URL?

    /// The face being dragged and the box it started from, so the gesture is absolute rather than
    /// an accumulation of per-callback deltas.
    private var dragFace: SectionBoxGeometry.Face?
    private var dragStartBounds: BoundingBox = .empty

    /// Feather width as a fraction of the model's largest extent.
    ///
    /// A hard cut through a wall reads as broken geometry; a soft edge reads as a section. Apple's
    /// sample can use a fixed inset because a mechanical part is always about the same size on
    /// screen — an architectural model is viewed at 1:1 in Immersive and at roughly 1:100 fitted
    /// into a one-metre volume, and a fixed 2 cm is either right or invisible depending on which.
    /// Proportional, with a 2 cm floor so a small part still gets the real-world value.
    static let featherFraction: Float = 0.005
    static let minimumFeather: Float = 0.02

    /// The cache is injectable for tests. Defaulted in the body rather than in the signature,
    /// because a default argument is evaluated in a nonisolated context and `shared` is
    /// main-actor isolated.
    init(cache: ClippingBoundsCache? = nil) {
        self.cache = cache ?? .shared
    }

    // MARK: - Lifecycle

    /// Points the tool at a model. Restores that model's last section if it has one.
    func bind(clipRoot: Entity, handleRoot: Entity, modelBounds: BoundingBox, key: URL?) {
        self.clipRoot = clipRoot
        self.handleRoot = handleRoot
        self.modelBounds = modelBounds
        self.modelKey = key
        self.bounds = key.flatMap { cache[$0] } ?? SectionBoxGeometry.initialBounds(modelBounds: modelBounds)
        self.state = .off
        applyClipping()
        rebuildHandles()
    }

    /// Turns the section on and shows its handles. The entry point from the toolbar.
    func activate() {
        guard clipRoot != nil else { return }
        if bounds.extents == .zero {
            bounds = SectionBoxGeometry.initialBounds(modelBounds: modelBounds)
        }
        state = .editing
        applyClipping()
        rebuildHandles()
    }

    /// Hides the handles but keeps the cut, or shows them again.
    func toggleEditing() {
        switch state {
        case .off: activate()
        case .on: state = .editing
        case .editing: state = .on
        }
        applyClipping()
        updateHandleVisibility()
    }

    /// Removes the component entirely, keeping the bounds so re-enabling restores the person's
    /// section rather than starting over from the model's full extent.
    func deactivate() {
        state = .off
        if let modelKey {
            cache[modelKey] = bounds
        }
        applyClipping()
        updateHandleVisibility()
    }

    /// Returns the box to the model's full extent without leaving the tool.
    func reset() {
        bounds = SectionBoxGeometry.initialBounds(modelBounds: modelBounds)
        applyClipping()
        layoutHandles()
    }

    // MARK: - Dragging

    /// Whether `entity` is one of this tool's handles, which is how the volume's single drag
    /// gesture decides between sectioning and exploding.
    func face(for entity: Entity) -> SectionBoxGeometry.Face? {
        handles.first { $0.value === entity }?.key
    }

    func beginDrag(face: SectionBoxGeometry.Face) {
        dragFace = face
        dragStartBounds = bounds
    }

    /// - Parameter displacement: the drag so far, already converted into the model's space.
    func updateDrag(displacement: SIMD3<Float>) {
        guard let dragFace else { return }
        bounds = SectionBoxGeometry.draggingFace(
            dragFace,
            by: displacement,
            from: dragStartBounds,
            within: modelBounds
        )
        applyClipping()
        layoutHandles()
    }

    func endDrag() {
        dragFace = nil
        if let modelKey {
            cache[modelKey] = bounds
        }
    }

    // MARK: - Applying

    private func applyClipping() {
        guard let clipRoot else { return }
        guard state != .off else {
            clipRoot.components.remove(ClippingComponent.self)
            return
        }

        var clipping = ClippingComponent(bounds: bounds)
        // Defaults to false, and false is useless here: the geometry is all in `clipRoot`'s
        // descendants, so without this the component clips an empty entity.
        clipping.shouldClipChildren = true
        clipping.shouldClipSelf = true
        clipping.featheredEdge.falloff = .linear
        let feather = max(
            Self.minimumFeather,
            max(modelBounds.extents.x, max(modelBounds.extents.y, modelBounds.extents.z)) * Self.featherFraction
        )
        let inset = SIMD3<Float>(repeating: feather)
        clipping.featheredEdge.positiveEdgeInset = inset
        clipping.featheredEdge.negativeEdgeInset = inset
        clipRoot.components.set(clipping)
    }

    /// Handles are built once per model and only re-laid-out afterwards. Regenerating six plane
    /// meshes per drag callback is the kind of per-frame allocation that shows up as a stutter
    /// rather than an error.
    private func rebuildHandles() {
        guard let handleRoot else { return }
        for handle in handles.values {
            handle.removeFromParent()
        }
        handles = [:]

        for face in SectionBoxGeometry.Face.allCases {
            let handle = ModelEntity(
                mesh: .generatePlane(width: 1, height: 1),
                materials: [Self.handleMaterial()]
            )
            handle.name = "section-\(face.rawValue)"
            handle.components.set(InputTargetComponent())
            handle.components.set(HoverEffectComponent())
            handle.isAccessibilityElement = true
            handle.accessibilityLabelKey = LocalizedStringResource("\(face.accessibilityName)")
            handles[face] = handle
            handleRoot.addChild(handle)
        }
        layoutHandles()
        updateHandleVisibility()
    }

    /// Positions, orients, and resizes each handle from the current bounds.
    ///
    /// The plane mesh stays 1×1 and is scaled, so a drag costs six transform writes rather than six
    /// mesh regenerations. Collision follows the same scale, which is what keeps the gaze target
    /// aligned with what is drawn.
    private func layoutHandles() {
        for (face, handle) in handles {
            var transform = SectionBoxGeometry.handleTransform(for: face, bounds: bounds)
            let size = SectionBoxGeometry.handleSize(for: face, bounds: bounds)
            transform.scale = SIMD3<Float>(max(size.x, 0.001), max(size.y, 0.001), 1)
            handle.transform = transform
            // A zero-thickness collider is unhittable, so the box gets a thin slab of depth.
            handle.components.set(CollisionComponent(
                shapes: [.generateBox(size: SIMD3<Float>(1, 1, 0.02))],
                mode: .trigger
            ))
        }
    }

    private func updateHandleVisibility() {
        let visible = state == .editing
        handleRoot?.isEnabled = visible
        for handle in handles.values {
            handle.isEnabled = visible
        }
    }

    /// Faintly tinted and unlit, so a handle reads as an affordance in front of the geometry rather
    /// than as a surface belonging to the model. The system hover effect supplies the targeting
    /// feedback, which on Vision Pro is what tells someone which face they are about to grab.
    private static func handleMaterial() -> UnlitMaterial {
        var material = UnlitMaterial(color: .white.withAlphaComponent(0.14))
        material.faceCulling = .none
        material.blending = .transparent(opacity: 1.0)
        return material
    }
}

/// Remembers each model's last section box for the lifetime of the app run.
///
/// Turning the tool off has to keep the box: someone who cuts down to a single storey, looks at it
/// with the handles hidden, switches the tool off to see the whole building, and switches it back
/// on has not asked to lose their section. Keyed by file URL so two exchanges don't share one.
@MainActor
final class ClippingBoundsCache {
    static let shared = ClippingBoundsCache()

    private var boxes: [URL: BoundingBox] = [:]

    subscript(key: URL) -> BoundingBox? {
        get { boxes[key] }
        set { boxes[key] = newValue }
    }

    func removeAll() {
        boxes = [:]
    }
}
