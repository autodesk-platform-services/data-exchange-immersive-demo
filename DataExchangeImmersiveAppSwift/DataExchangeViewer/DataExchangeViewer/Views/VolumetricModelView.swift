//
//  VolumetricModelView.swift
//  DataExchangeViewer
//

import SwiftUI
import RealityKit

/// Shows the currently selected USDZ model inside a bounded volumetric window, sized to be
/// inspected up close. Unlike the portal or the immersive space, the model here is directly
/// reachable, so it supports hand-driven drag/rotate/scale and gaze highlighting.
struct VolumetricModelView: View {
    let fileURL: URL?

    var body: some View {
        ModelContainerRealityView(
            fileURL: fileURL,
            withBackground: false,
            prepare: Self.prepareForVolumetricViewing
        )
    }

    /// Centers and normalizes the model to comfortably fit the volume's default bounds, then
    /// makes it directly grabbable/rotatable/scalable by hand, with a gaze highlight so it reads
    /// as interactive.
    private static func prepareForVolumetricViewing(_ entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let maxDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard maxDimension > 0 else { return }

        let targetSize: Float = 0.5
        let scale = targetSize / maxDimension
        entity.scale = SIMD3<Float>(repeating: scale)
        entity.position = -(bounds.center * scale)

        entity.components.set(HoverEffectComponent())
        ManipulationComponent.configureEntity(entity)
    }
}
