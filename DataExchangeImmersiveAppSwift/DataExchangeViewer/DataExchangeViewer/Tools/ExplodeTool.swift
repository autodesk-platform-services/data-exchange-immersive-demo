//
//  ExplodeTool.swift
//  DataExchangeViewer
//

import Foundation
import SwiftUI
import RealityKit
import simd

/// Separates the model's sub-assemblies along one axis, driven continuously by a drag.
///
/// The WWDC sample this follows fires one-shot `FromToBy` animations between collapsed and
/// exploded. A gesture-driven explode can't: the model has to be wherever the hand currently is, at
/// any fraction, and reverse when the hand does. So the offsets are computed once (in
/// `ExplodeLayout`) and the tool only carries a factor, which it writes into the parts as it moves.
///
/// While this tool is active the parts' transforms belong to it alone — no `ManipulationComponent`
/// anywhere in the model. Pulling one part free by hand is a separate behaviour, not this one.
@MainActor
@Observable
final class ExplodeTool {
    private(set) var isActive = false

    /// How far along the explode, 0…1. Observed by the toolbar's readout.
    private(set) var factor: Float = 0

    private weak var store: ModelStore?

    /// Drag distance along the axis needed for a full explode, as a fraction of the model's extent
    /// along that axis. Less than one so the whole range is reachable in a single comfortable hand
    /// travel — pinch-dragging the full height of the model is not a gesture people finish.
    static let travelFraction: Float = 0.6

    private var dragStartFactor: Float = 0

    func bind(to store: ModelStore) {
        self.store = store
        isActive = false
        factor = 0
    }

    /// - Returns: whether there was anything to explode. A flattened export has one part, and
    ///   activating on it would present a tool that visibly does nothing.
    @discardableResult
    func activate() -> Bool {
        guard let store, store.explodableParts.count > 1 else { return false }
        isActive = true
        factor = 0
        return true
    }

    /// Animates the parts home and gives their transforms back.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        factor = 0
        store?.resetExplode(animated: true)
    }

    func beginDrag() {
        dragStartFactor = factor
    }

    /// - Parameter displacement: the drag so far, already converted into the model's space.
    func updateDrag(displacement: SIMD3<Float>) {
        guard isActive, let store else { return }

        let axis = store.explodeAxis
        let extent = abs(simd_dot(store.bounds.extents, axis))
        let travel = max(extent * Self.travelFraction, 0.001)
        let along = simd_dot(displacement, axis)

        factor = min(max(dragStartFactor + along / travel, 0), 1)
        store.setExplodeFactor(factor)
    }

    func endDrag() {
        dragStartFactor = factor
    }

    /// Sets the factor without a gesture — the toolbar's slider, and the accessible path to a tool
    /// whose only other input is a pinch-drag in mid-air.
    func setFactor(_ newFactor: Float) {
        guard isActive, let store else { return }
        factor = min(max(newFactor, 0), 1)
        store.setExplodeFactor(factor)
    }

    /// A description of the axis for the toolbar, so the person can see *why* the model is coming
    /// apart the way it is — and tell a wrong axis from a wrong model.
    var axisName: String {
        guard let store else { return "" }
        let axis = store.explodeAxis
        if abs(axis.y) > 0.9 { return String(localized: "vertically") }
        if abs(axis.x) > 0.9 { return String(localized: "left to right") }
        return String(localized: "front to back")
    }
}
