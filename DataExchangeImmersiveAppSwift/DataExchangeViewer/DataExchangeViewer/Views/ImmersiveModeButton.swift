//
//  ImmersiveModeButton.swift
//  DataExchangeViewer
//

import SwiftUI

/// A button that opens the immersive space in a specific style, or exits it if that style is
/// already active. While a style is active, the button for the other style is disabled — the
/// user must exit first, so only one presentation mode is ever visible at once.
struct ImmersiveModeButton: View {
    let fileURL: URL?
    let kind: ImmersionKind
    let label: String
    let systemImage: String

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    private var isActive: Bool {
        appModel.immersiveSpaceState != .closed && appModel.immersionKind == kind
    }

    var body: some View {
        Button {
            Task { @MainActor in
                if isActive {
                    appModel.immersiveSpaceState = .inTransition
                    await dismissImmersiveSpace()
                    // Only set .closed in ImmersiveModelView.onDisappear(), since there
                    // may be multiple paths that dismiss the immersive space.
                } else if appModel.immersiveSpaceState == .closed, let fileURL {
                    appModel.immersiveModelURL = fileURL
                    appModel.immersionKind = kind
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
        } label: {
            Label(isActive ? "Exit" : label, systemImage: isActive ? "arrow.down.right.and.arrow.up.left" : systemImage)
        }
        .disabled(
            appModel.immersiveSpaceState == .inTransition
            || (appModel.immersiveSpaceState == .closed && fileURL == nil)
            || (appModel.immersiveSpaceState != .closed && !isActive)
        )
        .animation(.none, value: 0)
    }
}
