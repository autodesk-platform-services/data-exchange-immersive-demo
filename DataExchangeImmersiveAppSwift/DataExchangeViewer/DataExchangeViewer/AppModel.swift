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

    /// The volumetric window's scene id.
    let volumeWindowID = "model-volume"
    /// The immersive space's scene id.
    let immersiveSpaceID = "model-immersive"

    var immersiveSpaceState: ImmersiveSpaceState = .closed
    /// Whether the volumetric window is on screen. Set by `VolumeView`'s own appearance rather
    /// than guessed from the mode, because the system can close a volume without asking us.
    var isVolumeOpen = false

    /// Restored from defaults, and written back on every change, so reopening the app comes back to
    /// the way the person was looking at models — except Immersive, which never auto-restores.
    ///
    /// Computed over private storage rather than a stored property with a `didSet`, because
    /// `@Observable` synthesises its own accessors for stored properties and a property observer on
    /// one is at best fragile.
    var selectedPreviewMode: PreviewMode {
        get { storedPreviewMode }
        set {
            guard newValue != storedPreviewMode else { return }
            storedPreviewMode = newValue
            PreviewModeDefaults.store(newValue)
        }
    }

    private var storedPreviewMode: PreviewMode

    /// Immersive mode is `.full` only: in a 1:1 walkthrough of a building, the room showing through
    /// gives two conflicting senses of where the floor is.
    var immersionStyle: any ImmersionStyle = FullImmersionStyle()

    /// Number of mode switches currently in flight. Counted rather than a single flag because two
    /// transitions can overlap — the picker's own task and a scene's `onChange` — and the picker
    /// has to stay disabled until the last of them finishes animating.
    private var modeSwitchDepth = 0

    /// True for the whole asynchronous open/dismiss sequence, so controls don't accept another mode
    /// selection while the system is still changing scene presentation.
    var isSwitchingMode: Bool { modeSwitchDepth > 0 }

    init() {
        PreviewModeDefaults.migrate()
        storedPreviewMode = PreviewModeDefaults.restoredMode()
    }

    func beginModeSwitch() {
        modeSwitchDepth += 1
    }

    func endModeSwitch() {
        modeSwitchDepth = max(0, modeSwitchDepth - 1)
    }

    /// The USDZ file the preview modes should display.
    var previewModelURL: URL?

    /// The exchange name paired with `previewModelURL`, used to give the loaded RealityKit entity a
    /// meaningful VoiceOver label — not needed for the file to load or display.
    var previewModelName: String?

    /// The portal renders only when it is the active mode and no other scene owns the model. The
    /// model is a single entity re-parented between scenes, so a portal that kept drawing during
    /// Volume or Immersive would be drawing an empty world.
    var isPortalVisible: Bool {
        selectedPreviewMode == .portal && immersiveSpaceState == .closed && !isVolumeOpen
    }

    /// Whether a mode switch of any kind is in flight, for UI that should disable input or show a
    /// transitional state while it's ambiguous which mode is active.
    var isTransitioning: Bool { immersiveSpaceState == .inTransition || isSwitchingMode }

    func setPreviewModel(url: URL, name: String) {
        previewModelURL = url
        previewModelName = name
    }

    func clearPreviewModel() {
        previewModelURL = nil
        previewModelName = nil
    }

    /// Called when the immersive space goes away, including when the system dismisses it rather
    /// than the app. Returning to Portal is what restores the main window's own presentation.
    func immersiveSpaceDidClose() {
        immersiveSpaceState = .closed
        selectedPreviewMode = .portal
    }

    func volumeDidClose() {
        isVolumeOpen = false
        // Only fall back to Portal if the volume was the active presentation. A volume closed
        // *because* the person went immersive must not drag the mode back.
        if selectedPreviewMode == .volume {
            selectedPreviewMode = .portal
        }
    }
}
