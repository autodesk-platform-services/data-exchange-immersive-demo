//
//  ImmersiveModelView.swift
//  DataExchangeViewer
//

import SwiftUI
import RealityKit

/// Shows the currently selected USDZ model in the immersive space, either as a normalized
/// object in front of the viewer (`.mixed`) or at true scale, standing on the floor, so
/// buildings can be walked through (`.full`).
struct ImmersiveModelView: View {
    @Environment(AppModel.self) private var appModel
    @State private var root = Entity()
    @State private var modelContainer = Entity()
    @State private var loadedEntity: Entity?

    var body: some View {
        RealityView { content in
            root.addChild(modelContainer)
            content.add(root)

            if let environment = try? await StudioLighting.makeEnvironment() {
                try? StudioLighting.apply(environment, to: root, withBackground: appModel.immersionKind == .full)
            }
        } update: { _ in
            // Only the model container is touched here, so the lighting/background entities
            // added above (siblings of modelContainer under `root`) are left untouched.
            modelContainer.children.removeAll()
            if let loadedEntity {
                modelContainer.addChild(loadedEntity)
            }
        }
        .task(id: appModel.immersiveModelURL) {
            loadedEntity = nil
            guard let url = appModel.immersiveModelURL else { return }
            guard let entity = try? await Entity(contentsOf: url) else { return }
            Self.prepareForImmersiveViewing(entity, kind: appModel.immersionKind)
            loadedEntity = entity
        }
    }

    private static func prepareForImmersiveViewing(_ entity: Entity, kind: ImmersionKind) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let maxDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard maxDimension > 0 else { return }

        switch kind {
        case .mixed:
            // Normalize to a comfortable, inspectable size, and place it closer to the viewer
            // than the main window sits (~1.5m by default) so it reads as being in front of the
            // window instead of intersecting it.
            let targetSize: Float = 1.0
            let scale = targetSize / maxDimension
            entity.scale = SIMD3<Float>(repeating: scale)
            let scaledCenter = bounds.center * scale
            entity.position = SIMD3<Float>(-scaledCenter.x, -scaledCenter.y + 1.3, -scaledCenter.z - 0.75)

        case .full:
            // Keep close to the model's real-world scale — data exchanges are often buildings
            // meant to be walked through — but shrink it if needed so it stays clear of the
            // visible background sphere's surface instead of poking through it.
            let halfWidth = bounds.extents.x / 2
            let halfDepth = bounds.extents.z / 2
            let height = bounds.extents.y
            let reach = (halfWidth * halfWidth + height * height + halfDepth * halfDepth).squareRoot()
            let safeRadius = StudioLighting.backgroundSphereRadius * 0.8
            let scale = reach > safeRadius ? safeRadius / reach : 1
            entity.scale = SIMD3<Float>(repeating: scale)

            let scaledCenter = bounds.center * scale
            entity.position = SIMD3<Float>(-scaledCenter.x, -bounds.min.y * scale, -scaledCenter.z)
        }
    }
}
