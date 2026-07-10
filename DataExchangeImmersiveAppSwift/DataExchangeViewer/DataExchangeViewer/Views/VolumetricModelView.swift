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
    @Environment(AppModel.self) private var appModel

    private static let hasSeenManipulationHintKey = "hasSeenVolumetricManipulationHint"
    @AppStorage(Self.hasSeenManipulationHintKey) private var hasSeenManipulationHint = false
    @State private var showHint = false

    var body: some View {
        ModelContainerRealityView(
            fileURL: fileURL,
            withBackground: false,
            modelAccessibilityLabel: appModel.previewModelName,
            prepare: Self.prepareForVolumetricViewing
        )
        .overlay(alignment: .bottom) {
            if showHint {
                Label("Pinch and drag to move, rotate, or resize", systemImage: "hand.pinch")
                    .padding()
                    .glassBackgroundEffect()
                    .padding(.bottom)
                    .transition(.opacity)
            }
        }
        // Hand manipulation has no visible affordance of its own, so this shows a one-time hint
        // the first time a model loads, gated by AppStorage so it never appears again afterward.
        .task(id: fileURL) {
            guard fileURL != nil, !hasSeenManipulationHint else { return }
            withAnimation { showHint = true }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showHint = false }
            hasSeenManipulationHint = true
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
