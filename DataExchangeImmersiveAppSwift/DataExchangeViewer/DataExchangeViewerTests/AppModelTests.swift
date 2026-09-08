//
//  AppModelTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
import SwiftUI
import RealityKit
@testable import DataExchangeViewer

/// The state machine behind the Portal / Volume / Immersive picker, which decides when the
/// in-window portal renders and when the picker accepts another selection.
@MainActor
@Suite("App model")
struct AppModelTests {
    private let modelURL = URL(fileURLWithPath: "/tmp/model.usdz")

    @Test func startsInPortalWithNothingElseOpen() {
        let model = AppModel()
        model.selectedPreviewMode = .portal
        #expect(model.immersiveSpaceState == .closed)
        #expect(!model.isVolumeOpen)
        #expect(model.isPortalVisible)
        #expect(!model.isTransitioning)
    }

    /// The portal is hidden while another scene owns the model. It is a single entity re-parented
    /// between scenes, so a portal that kept drawing would be drawing an empty world.
    @Test func portalIsHiddenWhileAnotherSceneOwnsTheModel() {
        let model = AppModel()
        model.immersiveSpaceState = .open
        model.selectedPreviewMode = .immersive
        #expect(!model.isPortalVisible)

        model.selectedPreviewMode = .portal
        // Still open: the space hasn't finished dismissing, so the portal would double up.
        #expect(!model.isPortalVisible)

        model.immersiveSpaceState = .closed
        model.isVolumeOpen = true
        #expect(!model.isPortalVisible)

        model.isVolumeOpen = false
        #expect(model.isPortalVisible)
    }

    /// Immersive is `.full` only — the mode's whole premise is that the room is replaced.
    @Test func usesFullImmersionOnly() {
        let model = AppModel()
        #expect(model.immersionStyle is FullImmersionStyle)
    }

    /// Two overlapping transitions (the picker's own task and a scene's `onChange`) used to set and
    /// clear a single Bool, so whichever finished first re-enabled the picker while the other was
    /// still animating.
    @Test func modeSwitchesNest() {
        let model = AppModel()
        model.beginModeSwitch()
        model.beginModeSwitch()
        #expect(model.isSwitchingMode)

        model.endModeSwitch()
        #expect(model.isSwitchingMode, "the outer transition is still in flight")

        model.endModeSwitch()
        #expect(!model.isSwitchingMode)
    }

    /// An unbalanced end must not leave the counter negative, which would make the next genuine
    /// transition report as already finished.
    @Test func unbalancedEndsCannotDriveTheCounterNegative() {
        let model = AppModel()
        model.endModeSwitch()
        model.endModeSwitch()
        #expect(!model.isSwitchingMode)

        model.beginModeSwitch()
        #expect(model.isSwitchingMode)
    }

    @Test func reportsTransitioningWhileTheSpaceIsOpening() {
        let model = AppModel()
        model.immersiveSpaceState = .inTransition
        #expect(model.isTransitioning)
    }

    /// Covers system dismissal as well as the picker's own path back, so closing the space always
    /// lands somewhere the app can render.
    @Test func closingTheSpaceReturnsToPortal() {
        let model = AppModel()
        model.setPreviewModel(url: modelURL, name: "Basement")
        model.selectedPreviewMode = .immersive
        model.immersiveSpaceState = .open

        model.immersiveSpaceDidClose()

        #expect(model.selectedPreviewMode == .portal)
        #expect(model.immersiveSpaceState == .closed)
        #expect(model.isPortalVisible)
    }

    /// The model URL survives dismissal: returning to a mode should not have to re-convert or
    /// re-download the exchange.
    @Test func closingTheSpaceKeepsTheLoadedModel() {
        let model = AppModel()
        model.setPreviewModel(url: modelURL, name: "Basement")
        model.immersiveSpaceDidClose()
        #expect(model.previewModelURL == modelURL)
        #expect(model.previewModelName == "Basement")
    }

    @Test func closingTheVolumeReturnsToPortal() {
        let model = AppModel()
        model.selectedPreviewMode = .volume
        model.isVolumeOpen = true

        model.volumeDidClose()

        #expect(!model.isVolumeOpen)
        #expect(model.selectedPreviewMode == .portal)
    }

    /// Going immersive dismisses the volume, and that dismissal must not drag the mode back to
    /// Portal behind the transition's back.
    @Test func aVolumeClosedByGoingImmersiveDoesNotChangeTheMode() {
        let model = AppModel()
        model.selectedPreviewMode = .volume
        model.isVolumeOpen = true

        // The picker sets the mode before dismissing the volume, precisely so this holds.
        model.selectedPreviewMode = .immersive
        model.volumeDidClose()

        #expect(model.selectedPreviewMode == .immersive)
        #expect(!model.isVolumeOpen)
    }

    @Test func clearingTheModelDropsBothTheURLAndTheName() {
        let model = AppModel()
        model.setPreviewModel(url: modelURL, name: "Basement")
        model.clearPreviewModel()
        #expect(model.previewModelURL == nil)
        #expect(model.previewModelName == nil)
    }
}
