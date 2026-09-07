//
//  USDzPreviewView.swift
//  DataExchangeViewer
//

import SwiftUI
import RealityKit

struct USDzPreviewView: View {
    let fileURL: URL?
    /// The exchange's display name, threaded down to the immersive preview so the loaded
    /// RealityKit entity has a meaningful VoiceOver label.
    let modelName: String
    /// Why there is no model to show yet. `fileURL` alone can't distinguish "still checking"
    /// from "nothing converted yet" from "the conversion failed", and those need different
    /// messages — see `unavailableContent`.
    let conversionState: ConversionState
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
                unavailableContent
            } else {
                ZStack(alignment: .bottom) {
                    if appModel.isPeekVisible {
                        GeometryReader3D { geometry in
                            RealityView { content in
                                portalWorldEntity.components.set(WorldComponent())
                                portalWorldEntity.addChild(modelContainer)
                                root.addChild(portalWorldEntity)

                                if let environment = try? await StudioLighting.makeEnvironment() {
                                    StudioLighting.apply(environment, to: portalWorldEntity)
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
                    } else if appModel.isTransitioning {
                        // Dismissing/opening a window or immersive space are separate windowing
                        // surfaces with their own lifecycles, so a true cross-fade isn't possible —
                        // this is an honest "something's happening" state for the gap between them.
                        ProgressView("Switching view…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Explicitly sized so its centered content doesn't get pulled down to the
                        // ZStack's `.bottom` alignment, where it would overlap the controls below.
                        ContentUnavailableView(
                            appModel.activeMode == .enter ? "Inside the model" : "Placed in your space",
                            systemImage: appModel.activeMode == .enter ? "figure.walk" : "move.3d"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        // Attached to the outer Group so Peek remains available while the spatial scene is open,
        // and Place/Enter remain visible (but disabled) before a conversion exists.
        .ornament(attachmentAnchor: .scene(.bottom)) {
            PreviewModePicker(fileURL: fileURL, modelName: modelName)
                .padding()
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

    /// Shown in place of the preview whenever there is no USDZ to display. The transient states
    /// (checking, converting) get a spinner because they resolve on their own; the terminal ones
    /// get a `ContentUnavailableView` because they need the person to do something.
    @ViewBuilder
    private var unavailableContent: some View {
        switch conversionState {
        case .checking:
            ProgressView("Checking the exchange status")

        case .running:
            VStack(spacing: 8) {
                ProgressView("Converting to USDZ")
                Text("Large exchanges can take a few minutes. The conversion log is available from the toolbar menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()

        case .failed(let message):
            ContentUnavailableView {
                Label("Conversion failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }

        // `.completed` without a file URL isn't reachable today (the store publishes the URL
        // before the state), but it falls back to the actionable message rather than a spinner.
        case .notConverted, .completed:
            ContentUnavailableView("Run a conversion to preview", systemImage: "cube")
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
