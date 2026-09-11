//
//  PreviewModePicker.swift
//  DataExchangeViewer
//

import SwiftUI

/// Presents previewing as one continuum — Portal in the window, Volume in the room, Immersive at
/// full size — and owns the scene transitions between them.
///
/// Each mode is a different *kind* of scene (a plain window, a volumetric window, an immersive
/// space), so switching is asynchronous scene presentation rather than a state change. Keeping that
/// in one place is what makes "exactly one mode is active" enforceable: every path through `select`
/// closes whatever the previous mode had open.
struct PreviewModePicker: View {
    let fileURL: URL?
    let modelName: String

    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        // A three-way exclusive choice is what `Picker` is for. It keeps the system hover effect,
        // which on Vision Pro *is* the targeting feedback for eye tracking, supplies the selection
        // semantics and the `.isSelected` accessibility trait, and its system material stays
        // legible against arbitrary passthrough.
        Picker("Preview mode", selection: modeSelection) {
            ForEach(PreviewMode.allCases) { mode in
                Text(mode.title)
                    .accessibilityHint(mode.hint)
                    .disabled(mode.requiresModel && fileURL == nil)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(appModel.isTransitioning)
        .opacity(appModel.isTransitioning ? 0.5 : 1)
        .padding(6)
        .glassBackgroundEffect()
    }

    /// Reads the active mode and routes a new selection through `select`, which owns the
    /// asynchronous scene work. Writing through a binding keeps the selection the picker's own state
    /// rather than something reconstructed from button taps.
    private var modeSelection: Binding<PreviewMode> {
        Binding(
            get: { appModel.selectedPreviewMode },
            set: { mode in
                // A disabled segment shouldn't be reachable, but the guard means a mode that needs
                // a converted file can never be entered without one.
                guard !mode.requiresModel || fileURL != nil else { return }
                select(mode)
            }
        )
    }

    private func select(_ mode: PreviewMode) {
        guard mode != appModel.selectedPreviewMode else { return }
        Task { @MainActor in
            appModel.beginModeSwitch()
            defer { appModel.endModeSwitch() }

            switch mode {
            case .portal:
                // The mode is set first so that the volume's own dismissal handler doesn't also
                // try to decide what the mode should be.
                appModel.selectedPreviewMode = .portal
                if appModel.isVolumeOpen {
                    dismissWindow(id: appModel.volumeWindowID)
                }
                if appModel.immersiveSpaceState != .closed {
                    appModel.immersiveSpaceState = .inTransition
                    await dismissImmersiveSpace()
                    // The space's own disappearance owns the final reset, because it also covers
                    // the system dismissing it without asking.
                }

            case .volume:
                guard let fileURL else { return }
                appModel.setPreviewModel(url: fileURL, name: modelName)
                appModel.selectedPreviewMode = .volume

                if appModel.immersiveSpaceState != .closed {
                    appModel.immersiveSpaceState = .inTransition
                    await dismissImmersiveSpace()
                }
                if !appModel.isVolumeOpen {
                    openWindow(id: appModel.volumeWindowID)
                }

            case .immersive:
                guard let fileURL else { return }
                appModel.setPreviewModel(url: fileURL, name: modelName)
                appModel.selectedPreviewMode = .immersive

                // Full immersion hides the app's own windows, but a volumetric window left open
                // behind it is a scene still holding a claim on the model — dismissed explicitly so
                // the model has exactly one home.
                if appModel.isVolumeOpen {
                    dismissWindow(id: appModel.volumeWindowID)
                }

                guard appModel.immersiveSpaceState == .closed else { return }
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
