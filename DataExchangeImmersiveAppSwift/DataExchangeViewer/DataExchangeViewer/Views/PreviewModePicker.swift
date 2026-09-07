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
        // A three-way exclusive choice is what `Picker` is for. The hand-built capsules this
        // replaced used `.buttonStyle(.plain)`, which suppresses the system hover effect — and on
        // Vision Pro hover *is* the targeting feedback for eye tracking, so there was no way to
        // tell what was about to be selected. `Picker` also supplies the selection semantics and
        // the `.isSelected` accessibility trait that were previously applied by hand, and its
        // system material stays legible against arbitrary passthrough where the hardcoded
        // black-and-white capsules did not.
        Picker("Preview mode", selection: modeSelection) {
            ForEach(Segment.all) { segment in
                Text(segment.title)
                    .accessibilityHint(segment.hint)
                    .disabled(segment.needsModel && fileURL == nil)
                    .tag(segment.mode)
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
    /// asynchronous immersive-space work. Writing through a binding keeps the selection the
    /// picker's own state rather than something reconstructed from button taps.
    private var modeSelection: Binding<AppModel.PreviewMode> {
        Binding(
            get: { appModel.selectedPreviewMode },
            set: { mode in
                // A disabled segment shouldn't be reachable, but the guard means a mode that
                // needs a converted file can never be entered without one.
                guard mode == .peek || fileURL != nil else { return }
                select(mode)
            }
        )
    }

    /// One segment of the picker. Kept as data so the labels, hints, and file requirement live in
    /// one place instead of being repeated per call.
    private struct Segment: Identifiable {
        let mode: AppModel.PreviewMode
        let title: String
        let hint: String

        var id: AppModel.PreviewMode { mode }
        /// Place and Enter both need a converted USDZ; Peek is available while one is on its way.
        var needsModel: Bool { mode != .peek }

        static let all: [Segment] = [
            Segment(
                mode: .peek,
                title: "Peek",
                hint: "Shows the model through a framed opening in this window"
            ),
            Segment(
                mode: .place,
                title: "Place",
                hint: "Places a model you can move, rotate, and resize in your surroundings"
            ),
            Segment(
                mode: .enter,
                title: "Enter",
                hint: "Expands the model to architectural scale with controls for flying through it while stationary"
            )
        ]
    }

    private func select(_ mode: AppModel.PreviewMode) {
        guard mode != appModel.selectedPreviewMode else { return }
        Task { @MainActor in
            appModel.beginModeSwitch()
            defer { appModel.endModeSwitch() }

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

                appModel.selectedPreviewMode = mode
                appModel.isFullImmersion = false
                appModel.immersionStyle = mode == .place
                    ? MixedImmersionStyle()
                    : ProgressiveImmersionStyle()

                // Changing between Place and Enter only changes the model transform and immersion
                // style, both of which are already set above. The loaded RealityKit scene remains
                // alive, so there is no space to open.
                guard appModel.immersiveSpaceState != .open else { return }

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
