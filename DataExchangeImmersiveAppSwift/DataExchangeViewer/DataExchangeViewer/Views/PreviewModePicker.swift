//
//  PreviewModePicker.swift
//  DataExchangeViewer
//

import SwiftUI

/// Lets the user switch between the three ways of previewing a model: the in-window portal, a
/// bounded volumetric window floating nearby, and a full immersive walkthrough. Selecting a mode
/// dismisses whichever one is currently active first, so only one is ever presented at a time.
struct PreviewModePicker: View {
    let fileURL: URL?

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Picker("Preview Mode", selection: Binding(
            get: { appModel.activeMode },
            set: { select($0) }
        )) {
            Label("Portal", systemImage: "cube.transparent").tag(AppModel.PreviewMode.portal)
            Label("Inspect", systemImage: "move.3d").tag(AppModel.PreviewMode.volumetric)
            Label("Walk Through", systemImage: "figure.walk").tag(AppModel.PreviewMode.immersive)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(fileURL == nil || appModel.immersiveSpaceState == .inTransition)
    }

    private func select(_ mode: AppModel.PreviewMode) {
        guard mode != appModel.activeMode, let fileURL else { return }
        Task { @MainActor in
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
                break

            case .volumetric:
                appModel.previewModelURL = fileURL
                openWindow(id: appModel.volumetricWindowID, value: fileURL)
                appModel.isVolumetricWindowOpen = true

            case .immersive:
                appModel.previewModelURL = fileURL
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
