//
//  AppModel.swift
//  DataExchangeViewer
//

import Foundation
import SwiftUI
import RealityKit

@MainActor
@Observable
final class AppModel {
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    /// The three stages of the spatial preview. Place and Enter share one immersive scene so
    /// switching between them preserves the loaded entity and its placement.
    enum PreviewMode: Equatable {
        /// A framed opening in the flat window, viewed from outside.
        case peek
        /// A tabletop-scale model placed directly in the person's surroundings.
        case place
        /// The same model expanded to architectural scale for walking through.
        case enter
    }

    let immersiveSpaceID = "ImmersiveModelSpace"

    var immersiveSpaceState: ImmersiveSpaceState = .closed
    var selectedPreviewMode: PreviewMode = .peek

    /// Bound to the single ImmersiveSpace scene. Place uses mixed immersion; Enter uses
    /// progressive immersion so the Digital Crown remains the system-native comfort control.
    var immersionStyle: any ImmersionStyle = MixedImmersionStyle()
    var isFullImmersion = false

    /// Number of mode switches currently in flight. Two overlapping transitions (the picker's
    /// own task and ImmersiveModelView's `onChange`) each used to set and clear a single Bool,
    /// so whichever finished first re-enabled the picker while the other was still animating.
    private var modeSwitchDepth = 0

    /// True for the whole asynchronous open/dismiss sequence, so controls don't accept another
    /// mode selection while the system is still changing scene presentation.
    var isSwitchingMode: Bool { modeSwitchDepth > 0 }

    func beginModeSwitch() {
        modeSwitchDepth += 1
    }

    func endModeSwitch() {
        modeSwitchDepth = max(0, modeSwitchDepth - 1)
    }

    /// The USDZ file the immersive space should display, set right before opening it.
    var previewModelURL: URL?

    /// The exchange name paired with `previewModelURL`, used only to give the loaded RealityKit
    /// entity a meaningful VoiceOver label — not needed for the file to load or display.
    var previewModelName: String?

    /// The last hand-authored tabletop placement. ImmersiveModelView captures it before Enter or
    /// dismissal and restores it when the person returns to Place.
    var placedModelTransform: Transform?

    var activeMode: PreviewMode { selectedPreviewMode }

    /// The in-window portal is hidden while Place or Enter owns the spatial presentation.
    var isPeekVisible: Bool { activeMode == .peek && immersiveSpaceState == .closed }

    /// Whether a mode switch (of any kind) is currently in flight, for UI that should disable
    /// input or show a transitional state while it's ambiguous which mode is active.
    var isTransitioning: Bool { immersiveSpaceState == .inTransition || isSwitchingMode }

    func setPreviewModel(url: URL, name: String) {
        if previewModelURL != url {
            placedModelTransform = nil
        }
        previewModelURL = url
        previewModelName = name
    }

    func immersiveSpaceDidClose() {
        immersiveSpaceState = .closed
        selectedPreviewMode = .peek
        // A new Place session should start in front of the person's current position. Placement is
        // retained while switching Place <-> Enter, but not after explicitly returning to Peek.
        placedModelTransform = nil
        isFullImmersion = false
        immersionStyle = MixedImmersionStyle()
    }
}
