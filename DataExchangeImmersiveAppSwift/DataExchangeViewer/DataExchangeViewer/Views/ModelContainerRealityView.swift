//
//  ModelContainerRealityView.swift
//  DataExchangeViewer
//

import SwiftUI
import RealityKit

/// Shared RealityView shell for the two preview modes that just place a loaded model in a lit
/// scene (`ImmersiveModelView`, `VolumetricModelView`): sets up a root/container entity pair,
/// applies studio lighting once, and reloads `fileURL` into the container whenever it changes.
///
/// `USDzPreviewView`'s portal mode isn't a good fit here — its `update` closure also resizes a
/// portal plane on every frame, which this shell doesn't know about.
struct ModelContainerRealityView: View {
    let fileURL: URL?
    let withBackground: Bool
    let prepare: (Entity) -> Void

    @State private var root = Entity()
    @State private var modelContainer = Entity()
    @State private var loadedEntity: Entity?

    var body: some View {
        RealityView { content in
            root.addChild(modelContainer)
            content.add(root)

            if let environment = try? await StudioLighting.makeEnvironment() {
                try? StudioLighting.apply(environment, to: root, withBackground: withBackground)
            }
        } update: { _ in
            // Only the model container is touched here, so the lighting/background entities
            // added above (siblings of modelContainer under `root`) are left untouched.
            modelContainer.children.removeAll()
            if let loadedEntity {
                modelContainer.addChild(loadedEntity)
            }
        }
        .task(id: fileURL) {
            loadedEntity = nil
            guard let fileURL, let entity = try? await Entity(contentsOf: fileURL) else { return }
            prepare(entity)
            loadedEntity = entity
        }
    }
}
