//
//  AppModel.swift
//  DataExchangeViewer
//

import Foundation
import SwiftUI

/// The two immersion styles the app supports for viewing a model outside the portal.
enum ImmersionKind: Equatable {
    /// The model appears alongside the user's real surroundings.
    case mixed
    /// The model (and its environment) fully replaces the user's surroundings.
    case full

    var style: ImmersionStyle {
        switch self {
        case .mixed: return .mixed
        case .full: return .full
        }
    }
}

@MainActor
@Observable
final class AppModel {
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    let immersiveSpaceID = "ImmersiveModelSpace"
    var immersiveSpaceState: ImmersiveSpaceState = .closed
    var immersionKind: ImmersionKind = .mixed

    /// The USDZ file the immersive space should display, set right before opening it.
    var immersiveModelURL: URL?

    /// The in-window portal is hidden whenever an immersive space is open (or transitioning),
    /// so only one presentation mode — portal, mixed, or full immersion — is visible at a time.
    var isPortalVisible: Bool { immersiveSpaceState == .closed }
}
