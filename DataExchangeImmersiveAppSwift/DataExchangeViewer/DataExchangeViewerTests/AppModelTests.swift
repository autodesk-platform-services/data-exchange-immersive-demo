//
//  AppModelTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
import SwiftUI
import RealityKit
@testable import DataExchangeViewer

/// The state machine behind the Peek / Place / Enter picker, which decides when the in-window
/// portal is visible and when the picker accepts another selection.
@MainActor
@Suite("App model")
struct AppModelTests {
    private let modelURL = URL(fileURLWithPath: "/tmp/model.usdz")

    @Test func startsInPeekWithNoImmersiveSpace() {
        let model = AppModel()
        #expect(model.selectedPreviewMode == .peek)
        #expect(model.immersiveSpaceState == .closed)
        #expect(model.isPeekVisible)
        #expect(!model.isTransitioning)
    }

    /// The portal is hidden while a spatial mode owns the presentation — otherwise the same model
    /// is on screen twice.
    @Test func peekIsHiddenWhileTheImmersiveSpaceIsOpen() {
        let model = AppModel()
        model.immersiveSpaceState = .open
        model.selectedPreviewMode = .place
        #expect(!model.isPeekVisible)

        model.selectedPreviewMode = .peek
        // Still open: the space hasn't finished dismissing, so the portal would double up.
        #expect(!model.isPeekVisible)
    }

    /// Two overlapping transitions (the picker's own task and `ImmersiveModelView.onChange`) used
    /// to set and clear a single Bool, so whichever finished first re-enabled the picker while the
    /// other was still animating.
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

    @Test func keepsThePlacementWhenTheSameModelIsSetAgain() {
        let model = AppModel()
        model.setPreviewModel(url: modelURL, name: "Basement")
        model.placedModelTransform = Transform(translation: SIMD3<Float>(1, 2, 3))

        model.setPreviewModel(url: modelURL, name: "Basement")
        #expect(model.placedModelTransform?.translation == SIMD3<Float>(1, 2, 3))
    }

    /// A hand-authored placement belongs to one model. Carrying it over to a different exchange
    /// would drop a differently sized model at the previous one's scale and position.
    @Test func discardsThePlacementForADifferentModel() {
        let model = AppModel()
        model.setPreviewModel(url: modelURL, name: "Basement")
        model.placedModelTransform = Transform(translation: SIMD3<Float>(1, 2, 3))

        model.setPreviewModel(url: URL(fileURLWithPath: "/tmp/other.usdz"), name: "Roof")
        #expect(model.placedModelTransform?.translation == nil)
        #expect(model.previewModelName == "Roof")
    }

    /// Covers system dismissal as well as the picker's own path back to Peek, so a new session
    /// starts in front of wherever the person is now.
    @Test func closingTheSpaceResetsToPeek() {
        let model = AppModel()
        model.setPreviewModel(url: modelURL, name: "Basement")
        model.selectedPreviewMode = .enter
        model.immersiveSpaceState = .open
        model.isFullImmersion = true
        model.immersionStyle = FullImmersionStyle()
        model.placedModelTransform = Transform(translation: SIMD3<Float>(1, 2, 3))

        model.immersiveSpaceDidClose()

        #expect(model.selectedPreviewMode == .peek)
        #expect(model.immersiveSpaceState == .closed)
        #expect(model.placedModelTransform?.translation == nil)
        #expect(!model.isFullImmersion)
        #expect(model.immersionStyle is MixedImmersionStyle)
        #expect(model.isPeekVisible)
    }

    /// The model URL survives dismissal: returning to Place should not have to re-convert or
    /// re-download the exchange.
    @Test func closingTheSpaceKeepsTheLoadedModel() {
        let model = AppModel()
        model.setPreviewModel(url: modelURL, name: "Basement")
        model.immersiveSpaceDidClose()
        #expect(model.previewModelURL == modelURL)
        #expect(model.previewModelName == "Basement")
    }
}
