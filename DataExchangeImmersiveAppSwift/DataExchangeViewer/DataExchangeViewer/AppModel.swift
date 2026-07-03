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

    /// The three ways a model can be previewed. Only one is ever active at a time.
    enum PreviewMode: Equatable {
        /// A framed opening in the flat window, viewed from outside.
        case portal
        /// A bounded volumetric window the model floats in, viewed up close and manipulated by hand.
        case volumetric
        /// A full immersive space, replacing the user's surroundings, sized for walking through.
        case immersive
    }

    let immersiveSpaceID = "ImmersiveModelSpace"
    let volumetricWindowID = "VolumetricModelSpace"

    var immersiveSpaceState: ImmersiveSpaceState = .closed
    var isVolumetricWindowOpen = false

    /// The USDZ file the volumetric window or immersive space should display, set right before opening either.
    var previewModelURL: URL?

    var activeMode: PreviewMode {
        if immersiveSpaceState != .closed { return .immersive }
        if isVolumetricWindowOpen { return .volumetric }
        return .portal
    }

    /// The in-window portal is hidden whenever another presentation mode is active (or transitioning),
    /// so only one of portal, volumetric, or full immersion is visible at a time.
    var isPortalVisible: Bool { activeMode == .portal }
}
