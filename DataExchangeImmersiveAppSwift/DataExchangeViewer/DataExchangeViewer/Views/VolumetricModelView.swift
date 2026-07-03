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
    @State private var root = Entity()
    @State private var modelContainer = Entity()
    @State private var loadedEntity: Entity?

    var body: some View {
        RealityView { content in
            root.addChild(modelContainer)
            content.add(root)

            if let environment = try? await StudioLighting.makeEnvironment() {
                try? StudioLighting.apply(environment, to: root, withBackground: false)
            }
        } update: { _ in
            // Only the model container is touched here, so the lighting entity added above
            // (a sibling of modelContainer under `root`) is left untouched.
            modelContainer.children.removeAll()
            if let loadedEntity {
                modelContainer.addChild(loadedEntity)
            }
        }
        .task(id: fileURL) {
            loadedEntity = nil
            guard let fileURL, let entity = try? await Entity(contentsOf: fileURL) else { return }
            Self.prepareForVolumetricViewing(entity)
            loadedEntity = entity
        }
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
