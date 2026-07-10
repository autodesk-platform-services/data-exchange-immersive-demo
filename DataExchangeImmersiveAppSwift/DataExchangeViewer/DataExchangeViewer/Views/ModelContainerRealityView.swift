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
    /// Lets the user drag the whole loaded model to reposition it, regardless of which of its
    /// (possibly deeply nested) child meshes the drag actually started on. Off by default since
    /// the volumetric mode already gets richer manipulation for free via `ManipulationComponent`.
    var enableDragToReposition: Bool = false
    /// Passed straight to the loaded entity's accessibility label so VoiceOver can announce and
    /// select the model by name, e.g. in the volumetric window.
    var modelAccessibilityLabel: String?
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
        .gesture(
            DragGesture()
                .targetedToEntity(modelContainer)
                .onChanged { value in
                    guard enableDragToReposition, let parent = modelContainer.parent else { return }
                    modelContainer.position = value.convert(value.location3D, from: .local, to: parent)
                }
        )
        .task(id: fileURL) {
            loadedEntity = nil
            guard let fileURL, let entity = try? await Entity(contentsOf: fileURL) else { return }
            prepare(entity)
            if let modelAccessibilityLabel {
                entity.isAccessibilityElement = true
                // accessibilityLabelKey is a LocalizedStringResource, not a plain String — wrapping
                // the whole value in one interpolation renders it verbatim, since exchange names
                // are runtime user data, not something to look up in a strings table.
                entity.accessibilityLabelKey = LocalizedStringResource("\(modelAccessibilityLabel)")
            }
            loadedEntity = entity
        }
    }
}
