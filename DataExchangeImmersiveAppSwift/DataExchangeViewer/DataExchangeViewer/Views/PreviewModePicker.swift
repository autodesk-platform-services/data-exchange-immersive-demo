//
//  PreviewModePicker.swift
//  DataExchangeViewer
//

import SwiftUI

/// Presents previewing as one continuum: Peek in the window, Place the model in the room, or
/// Enter it at architectural scale. Place and Enter reuse the same immersive scene instead of
/// dismissing one scene and opening another.
struct PreviewModePicker: View {
    let fileURL: URL?
    let modelName: String

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        HStack(spacing: 4) {
            segment("Peek", systemImage: "cube.transparent", mode: .peek,
                    hint: "Shows the model through a framed opening in this window")
            segment("Place", systemImage: "move.3d", mode: .place,
                    hint: "Places a model you can move, rotate, and resize in your surroundings")
            segment("Enter", systemImage: "figure.walk", mode: .enter,
                    hint: "Expands the model to architectural scale with controls for flying through it while stationary")
        }
        .padding(4)
        .background(.black.opacity(0.35), in: Capsule())
        .disabled(appModel.isTransitioning)
        .opacity(appModel.isTransitioning ? 0.5 : 1)
    }

    private func segment(
        _ title: String,
        systemImage: String,
        mode: AppModel.PreviewMode,
        hint: String
    ) -> some View {
        let isSelected = appModel.activeMode == mode
        let needsModel = mode != .peek
        return Button {
            select(mode)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.white : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(needsModel && fileURL == nil)
        .accessibilityHint(hint)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func select(_ mode: AppModel.PreviewMode) {
        guard mode != appModel.activeMode else { return }
        Task { @MainActor in
            appModel.isSwitchingMode = true
            defer { appModel.isSwitchingMode = false }

            switch mode {
            case .peek:
                guard appModel.immersiveSpaceState != .closed else {
                    appModel.selectedPreviewMode = .peek
                    return
                }
                appModel.immersiveSpaceState = .inTransition
                await dismissImmersiveSpace()
                // onDisappear owns the final reset because it also covers system dismissal.

            case .place, .enter:
                guard let fileURL else { return }
                appModel.setPreviewModel(url: fileURL, name: modelName)

                // Changing between Place and Enter only changes the model transform and immersion
                // style. The loaded RealityKit scene remains alive.
                if appModel.immersiveSpaceState == .open {
                    appModel.selectedPreviewMode = mode
                    appModel.isFullImmersion = false
                    appModel.immersionStyle = mode == .place
                        ? MixedImmersionStyle()
                        : ProgressiveImmersionStyle()
                    return
                }

                appModel.selectedPreviewMode = mode
                appModel.isFullImmersion = false
                appModel.immersionStyle = mode == .place
                    ? MixedImmersionStyle()
                    : ProgressiveImmersionStyle()
                appModel.immersiveSpaceState = .inTransition

                switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
                case .opened:
                    break
                case .userCancelled, .error:
                    fallthrough
                @unknown default:
                    appModel.immersiveSpaceDidClose()
                }
            }
        }
    }
}
