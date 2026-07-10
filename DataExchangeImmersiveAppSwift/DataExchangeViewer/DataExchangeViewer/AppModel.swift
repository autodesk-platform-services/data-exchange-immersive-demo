//
//  AppModel.swift
//  DataExchangeViewer
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    /// The ways a model (or its conversion log) can be shown. Only one is ever active at a time.
    enum PreviewMode: Equatable {
        /// A framed opening in the flat window, viewed from outside.
        case portal
        /// A bounded volumetric window the model floats in, viewed up close and manipulated by hand.
        case volumetric
        /// A full immersive space, replacing the user's surroundings, sized for walking through.
        case immersive
        /// The conversion log, shown in the flat window in place of the portal.
        case logs
    }

    let immersiveSpaceID = "ImmersiveModelSpace"
    let volumetricWindowID = "VolumetricModelSpace"

    var immersiveSpaceState: ImmersiveSpaceState = .closed
    var isVolumetricWindowOpen = false

    /// True for the whole dismiss-then-open sequence in `PreviewModePicker.select(_:)`, including
    /// legs that have no async system call of their own (e.g. switching to `.portal`), so the UI
    /// has one flag to show a "switching" state regardless of which mode is involved.
    var isSwitchingMode = false

    /// The USDZ file the volumetric window or immersive space should display, set right before opening either.
    var previewModelURL: URL?

    /// The exchange name paired with `previewModelURL`, used only to give the loaded RealityKit
    /// entity a meaningful VoiceOver label — not needed for the file to load or display.
    var previewModelName: String?

    /// The file most recently shown in the volumetric window, used to decide whether "Back to
    /// Inspect" from the immersive space would reopen the same model or a different one.
    var lastVolumetricFileURL: URL?

    /// Set when `.logs` is selected in the flat window. Only meaningful when neither the
    /// volumetric window nor the immersive space is open — those two always take priority.
    var isShowingLogs = false

    var activeMode: PreviewMode {
        if immersiveSpaceState != .closed { return .immersive }
        if isVolumetricWindowOpen { return .volumetric }
        return isShowingLogs ? .logs : .portal
    }

    /// The in-window portal is hidden whenever another presentation mode is active (or transitioning),
    /// so only one of portal, volumetric, or full immersion is visible at a time.
    var isPortalVisible: Bool { activeMode == .portal }

    /// Whether a mode switch (of any kind) is currently in flight, for UI that should disable
    /// input or show a transitional state while it's ambiguous which mode is active.
    var isTransitioning: Bool { immersiveSpaceState == .inTransition || isSwitchingMode }
}
