//
//  USDzPreviewView.swift
//  DataExchangeViewer
//

import SwiftUI
import RealityKit

struct USDzPreviewView: View {
    let fileURL: URL?
    @Environment(AppModel.self) private var appModel
    @State private var root = Entity()
    @State private var portalWorldEntity = Entity()
    @State private var modelContainer = Entity()
    @State private var portalPlane = ModelEntity(
        mesh: .generatePlane(width: 1.0, height: 1.0),
        materials: [PortalMaterial()]
    )
    @State private var loadedEntity: Entity?
    @State private var loadError: String?

    /// Fraction of each dimension kept as a gap between the portal opening and the edges of the
    /// space it occupies, so it reads as a framed opening rather than content that bleeds to the
    /// edges. Proportional (rather than a fixed size) so it scales with the space instead of
    /// swallowing whichever dimension happens to be smaller.
    private let portalMarginFraction: Float = 0.05

    var body: some View {
        Group {
            if fileURL == nil {
                ContentUnavailableView("Run a conversion to preview", systemImage: "cube")
            } else {
                ZStack(alignment: .bottom) {
                    if appModel.isPortalVisible {
                        GeometryReader3D { geometry in
                            RealityView { content in
                                portalWorldEntity.components.set(WorldComponent())
                                portalWorldEntity.addChild(modelContainer)
                                root.addChild(portalWorldEntity)

                                if let environment = try? await StudioLighting.makeEnvironment() {
                                    try? StudioLighting.apply(environment, to: portalWorldEntity)
                                }

                                portalPlane.components.set(PortalComponent(target: portalWorldEntity))
                                root.addChild(portalPlane)

                                content.add(root)
                            } update: { content in
                                // Only the model container is touched here, so the lighting/background
                                // entities added above (siblings under portalWorldEntity) stay in place.
                                modelContainer.children.removeAll()
                                if let loadedEntity {
                                    modelContainer.addChild(loadedEntity)
                                }

                                let size = content.convert(geometry.size, from: .local, to: .scene)
                                let width = size.x * (1 - portalMarginFraction)
                                let height = size.y * (1 - portalMarginFraction)
                                portalPlane.model?.mesh = .generatePlane(width: width, height: height, cornerRadius: 0.02)
                            }
                            .frame(depth: 0.4)
                        }
                        .frame(depth: 0.4)

                        if let loadError {
                            Text(loadError)
                                .foregroundStyle(.red)
                                .padding()
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        // Explicitly sized so its centered content doesn't get pulled down to the
                        // ZStack's `.bottom` alignment, where it would overlap the controls below.
                        ContentUnavailableView(
                            appModel.activeMode == .immersive ? "Viewing in full space" : "Viewing in a separate window",
                            systemImage: appModel.activeMode == .immersive ? "figure.walk" : "move.3d"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    HStack(spacing: 16) {
                        PreviewModePicker(fileURL: fileURL)
                        QuickLookButton(fileURL: fileURL)
                    }
                    .padding()
                    // A shared glass backdrop so the controls stay legible over the portal's
                    // RealityView content instead of just the picker's selected segment
                    // providing contrast.
                    .glassBackgroundEffect()
                    .padding(.bottom)
                }
            }
        }
        .task(id: fileURL) {
            loadedEntity = nil
            loadError = nil
            guard let fileURL else { return }
            do {
                let entity = try await Entity(contentsOf: fileURL)
                Self.fitBehindPortal(entity)
                loadedEntity = entity
            } catch {
                loadError = "Failed to load preview: \(error.localizedDescription)"
            }
        }
    }

    /// USDZ files bake in their own arbitrary position/scale, which otherwise lands the model right
    /// at (or in front of) the portal opening instead of receding behind it. This centers and scales
    /// the loaded entity to a consistent size, then pushes it back in -z (away from the viewer) so it
    /// reads as embedded inside the portal rather than popping out in front of the window.
    private static func fitBehindPortal(_ entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let maxDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard maxDimension > 0 else { return }

        let targetSize: Float = 0.35
        let scale = targetSize / maxDimension
        entity.scale = SIMD3<Float>(repeating: scale)

        let scaledCenter = bounds.center * scale
        let pushBack: Float = 0.3
        entity.position = SIMD3<Float>(-scaledCenter.x, -scaledCenter.y, -scaledCenter.z - pushBack)
    }
}
