import SwiftUI
import RealityKit
import simd

/// A single movable cut. The other five bounds stay outside the design.
@MainActor
@Observable
final class PlaneClippingTool {
    private(set) var isActive = false
    private(set) var axis: ToolAxis = .y
    private(set) var fraction: Float = 0.5
    private(set) var isFlipped = false
    private(set) var showsHandle = true
    private weak var clipRoot: Entity?
    private var handle: ModelEntity?
    private var modelBounds: BoundingBox = .empty
    private var dragStart: Float = 0.5

    func bind(clipRoot: Entity, overlay: Entity, bounds: BoundingBox) {
        deactivate()
        handle?.removeFromParent()
        self.clipRoot = clipRoot
        modelBounds = bounds
        axis = .y
        fraction = 0.5
        isFlipped = false
        var material = UnlitMaterial(color: .cyan.withAlphaComponent(0.2))
        material.faceCulling = .none
        material.blending = .transparent(opacity: 1.0)
        let handle = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [material])
        handle.name = "clipping-plane"
        handle.components.set(InputTargetComponent())
        handle.components.set(HoverEffectComponent())
        handle.components.set(CollisionComponent(shapes: [.generateBox(size: [1, 1, 0.02])], mode: .trigger))
        handle.isAccessibilityElement = true
        handle.accessibilityLabelKey = "Clipping plane"
        handle.isEnabled = false
        overlay.addChild(handle)
        self.handle = handle
    }

    func activate() {
        guard clipRoot != nil else { return }
        isActive = true
        showsHandle = true
        apply()
    }

    func deactivate() {
        if isActive { clipRoot?.components.remove(ClippingComponent.self) }
        isActive = false
        handle?.isEnabled = false
    }

    func setAxis(_ axis: ToolAxis) {
        self.axis = axis
        apply()
    }
    func setFraction(_ fraction: Float) {
        self.fraction = min(max(fraction, 0), 1)
        apply()
    }
    func flip() { isFlipped.toggle(); apply() }
    func toggleHandle() { showsHandle.toggle(); apply() }
    func reset() {
        fraction = 0.5
        isFlipped = false
        apply()
    }
    func owns(_ entity: Entity) -> Bool { entity === handle }
    func beginDrag() { dragStart = fraction }
    func updateDrag(displacement: SIMD3<Float>) {
        guard isActive else { return }
        setFraction(dragStart + displacement[axis.index] / max(modelBounds.extents[axis.index], 0.001))
    }

    static func clippingBounds(model: BoundingBox, axis: ToolAxis, fraction: Float, flipped: Bool) -> BoundingBox {
        let padding = SIMD3<Float>(repeating: max(simd_length(model.extents), 0.001))
        var low = model.min - padding
        var high = model.max + padding
        let coordinate = model.min[axis.index] + model.extents[axis.index] * min(max(fraction, 0), 1)
        if flipped { low[axis.index] = coordinate } else { high[axis.index] = coordinate }
        return BoundingBox(min: low, max: high)
    }

    private func apply() {
        guard isActive, let clipRoot, let handle else { return }
        var clipping = ClippingComponent(bounds: Self.clippingBounds(
            model: modelBounds, axis: axis, fraction: fraction, flipped: isFlipped
        ))
        clipping.shouldClipChildren = true
        clipping.shouldClipSelf = true
        clipRoot.components.set(clipping)
        let face: SectionBoxGeometry.Face = switch axis {
        case .x: .maxX
        case .y: .maxY
        case .z: .maxZ
        }
        var transform = SectionBoxGeometry.handleTransform(for: face, bounds: modelBounds)
        transform.translation[axis.index] = modelBounds.min[axis.index] + modelBounds.extents[axis.index] * fraction
        let size = SectionBoxGeometry.handleSize(for: face, bounds: modelBounds)
        transform.scale = [max(size.x, 0.001), max(size.y, 0.001), 1]
        handle.transform = transform
        handle.isEnabled = showsHandle
    }
}
