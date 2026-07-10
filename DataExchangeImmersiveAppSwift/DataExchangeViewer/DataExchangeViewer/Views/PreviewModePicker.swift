//
//  PreviewModePicker.swift
//  DataExchangeViewer
//

import SwiftUI

/// Lets the user switch between the ways of viewing an exchange: the in-window portal, a bounded
/// volumetric window floating nearby, a full immersive walkthrough, or the conversion log.
/// Selecting a mode dismisses whichever one is currently active first, so only one is ever
/// presented at a time. Portal and Logs work without a converted file; Inspect and Walk Through
/// need one and no-op if selected too early.
struct PreviewModePicker: View {
    let fileURL: URL?
    let modelName: String

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// The system segmented style dims unselected labels in a way that isn't overridable and reads
    /// as illegible against most backgrounds — so this draws its own segments with explicit,
    /// always-legible colors instead of relying on `.pickerStyle(.segmented)`.
    var body: some View {
        HStack(spacing: 4) {
            segment("Portal", systemImage: "cube.transparent", mode: .portal,
                    hint: "Shows the model through a framed opening in this window")
            segment("Inspect", systemImage: "move.3d", mode: .volumetric,
                    hint: "Opens the model in a nearby window you can pick up and examine")
            segment("Walk Through", systemImage: "figure.walk", mode: .immersive,
                    hint: "Replaces your surroundings with the model at full scale")
            segment("Logs", systemImage: "doc.plaintext", mode: .logs,
                    hint: "Shows the conversion log in this window")
        }
        .padding(4)
        .background(.black.opacity(0.35), in: Capsule())
        .disabled(appModel.isTransitioning)
        .opacity(appModel.isTransitioning ? 0.5 : 1)
    }

    private func segment(_ title: String, systemImage: String, mode: AppModel.PreviewMode, hint: String) -> some View {
        let isSelected = appModel.activeMode == mode
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
        .accessibilityHint(hint)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func select(_ mode: AppModel.PreviewMode) {
        guard mode != appModel.activeMode else { return }
        Task { @MainActor in
            appModel.isSwitchingMode = true
            defer { appModel.isSwitchingMode = false }

            if appModel.isVolumetricWindowOpen {
                dismissWindow(id: appModel.volumetricWindowID)
                appModel.isVolumetricWindowOpen = false
            }
            if appModel.immersiveSpaceState != .closed {
                appModel.immersiveSpaceState = .inTransition
                await dismissImmersiveSpace()
                // Only set .closed in ImmersiveModelView's onDisappear(), since there
                // may be multiple paths that dismiss the immersive space.
            }

            switch mode {
            case .portal:
                appModel.isShowingLogs = false

            case .logs:
                appModel.isShowingLogs = true

            case .volumetric:
                // No-op if selected before a file exists — Inspect/Walk Through need one to open.
                guard let fileURL else { return }
                appModel.isShowingLogs = false
                appModel.previewModelURL = fileURL
                appModel.previewModelName = modelName
                appModel.lastVolumetricFileURL = fileURL
                openWindow(id: appModel.volumetricWindowID, value: fileURL)
                appModel.isVolumetricWindowOpen = true

            case .immersive:
                guard let fileURL else { return }
                appModel.isShowingLogs = false
                appModel.previewModelURL = fileURL
                appModel.previewModelName = modelName
                appModel.immersiveSpaceState = .inTransition
                switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
                case .opened:
                    break
                case .userCancelled, .error:
                    fallthrough
                @unknown default:
                    appModel.immersiveSpaceState = .closed
                }
            }
        }
    }
}
