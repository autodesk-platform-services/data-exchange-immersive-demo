//
//  LocomotionController.swift
//  DataExchangeViewer
//

import Foundation
import SwiftUI
import RealityKit
import simd

/// Virtual locomotion for Immersive mode.
///
/// visionOS gives no API to reposition the wearer, so travelling through a building at 1:1 means
/// moving the *world* in the opposite direction. This drives one entity — the world rig holding the
/// model — from a thumbstick-style puck and an altitude slider, and remembers the entry pose so
/// there is always a way back.
///
/// Comfort constraints are structural here, not adjustable polish:
///
/// - **No rotation.** Nothing here yaws the world. Turning is done by turning your head or body,
///   because controller-driven rotation is the single largest contributor to discomfort and 20–30
///   minute review sessions are the assumption.
/// - **Constant velocity.** The puck maps to a fixed speed with no acceleration curve. Predictable
///   beats smooth: an accelerating world is a vestibular mismatch that a constant one avoids.
/// - **Separate axes.** Horizontal travel integrates over time (a joystick); altitude is absolute
///   (a slider). Someone who wants to be six metres up gets there and stays, with no drift.
@MainActor
@Observable
final class LocomotionController {
    /// A multiplier on the base speed. Model size can't tell inspecting one room apart from
    /// crossing a site, so the choice stays with the person.
    enum Speed: String, CaseIterable, Identifiable, Sendable {
        case slow
        case walk
        case fast

        var id: Self { self }

        var title: String {
            switch self {
            case .slow: String(localized: "Slow")
            case .walk: String(localized: "Walk")
            case .fast: String(localized: "Fast")
            }
        }

        var multiplier: Float {
            switch self {
            case .slow: 0.5
            case .walk: 1
            case .fast: 3
            }
        }
    }

    /// Metres per second at a multiplier of 1 — a deliberate walking pace rather than something
    /// derived from the model's size, because at 1:1 the model's size is the real building's size
    /// and a walk is a walk.
    static let baseSpeed: Float = 1.4

    /// Time constant for the altitude slider's easing, in seconds. The slider is absolute, so
    /// without this a drag across it would teleport the wearer vertically.
    static let altitudeSmoothingTime: Float = 0.25

    /// Time constant for the vignette fading in and out.
    static let vignetteFadeTime: Float = 0.2

    var speed: Speed = .walk

    /// The puck's output, in −1…1 on each axis: x right, y *down* (screen convention). Written by
    /// the control's drag gesture and read once per frame.
    ///
    /// Computed over private storage rather than a stored property with a `didSet`, so the clamp
    /// can't be bypassed and so it stays compatible with `@Observable`'s accessor synthesis.
    var stick: SIMD2<Float> {
        get { stickInput }
        set { stickInput = Self.clampedToUnitDisc(newValue) }
    }

    private var stickInput: SIMD2<Float> = .zero

    /// How far the wearer has risen above the entry height, in meters. The slider's value.
    var altitude: Float = 0

    /// 0…1, following whether the world is currently translating. Drives the comfort vignette.
    private(set) var vignetteIntensity: Float = 0

    /// How far the person has travelled from the entry point, for the controls' readout — the one
    /// number that tells someone who is lost inside a wall how lost they are.
    private(set) var distanceFromEntry: Float = 0

    private weak var worldRoot: Entity?
    private var entryTransform: Transform = .init()
    /// Accumulated horizontal displacement of the world. Held separately from the entity's
    /// transform so altitude can be absolute while travel is integrated.
    private var horizontalOffset: SIMD3<Float> = .zero
    private var smoothedAltitude: Float = 0
    private var viewerFrame: () -> ModelPlacement.ViewerFrame = {
        ModelPlacement.viewerFrame(from: nil)
    }
    private var updateSubscription: EventSubscription?

    /// Below this the puck is at rest — a pinch held still still wobbles by a pixel or two.
    private static let deadZone: Float = 0.05

    /// Starts the per-frame update. Called from `RealityView`'s `make` closure, which runs once, so
    /// the subscription is created once for the life of the scene.
    ///
    /// `viewerFrame` is read every frame rather than captured at press time, which is what lets
    /// someone steer mid-flight by turning their head.
    func attach(
        to content: RealityViewContent,
        viewerFrame: @escaping () -> ModelPlacement.ViewerFrame
    ) {
        self.viewerFrame = viewerFrame
        updateSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.step(deltaTime: Float(event.deltaTime))
        }
    }

    /// Points the controller at the world rig and records the pose `recentre` returns to.
    func setTarget(_ entity: Entity?, entryTransform: Transform) {
        worldRoot = entity
        self.entryTransform = entryTransform
        horizontalOffset = .zero
        altitude = 0
        smoothedAltitude = 0
        stick = .zero
        distanceFromEntry = 0
        applyTransform()
    }

    /// Back to the entry pose. Always available, and the escape hatch when someone has flown inside
    /// a wall and has no idea which way is out.
    func recentre() {
        stick = .zero
        horizontalOffset = .zero
        altitude = 0
        guard let worldRoot else {
            smoothedAltitude = 0
            return
        }
        // Animated rather than snapped: an instantaneous jump of tens of metres is the one motion
        // guaranteed to be uncomfortable, and this is the control people reach for when they are
        // already disoriented.
        worldRoot.move(to: entryTransform, relativeTo: worldRoot.parent, duration: 0.4, timingFunction: .easeInOut)
        smoothedAltitude = 0
        distanceFromEntry = 0
    }

    /// Applies one frame of travel.
    private func step(deltaTime: Float) {
        guard worldRoot != nil, deltaTime > 0, deltaTime < 1 else { return }

        let horizontalSpeed = simd_length(stick) > Self.deadZone
            ? velocity(for: stick)
            : SIMD3<Float>.zero

        // The wearer is the camera, so the world moves opposite the intended direction of travel.
        horizontalOffset -= horizontalSpeed * deltaTime

        let altitudeError = altitude - smoothedAltitude
        smoothedAltitude += altitudeError * min(1, deltaTime / Self.altitudeSmoothingTime)

        let isMoving = horizontalSpeed != .zero || abs(altitudeError) > 0.005
        let vignetteTarget: Float = isMoving ? 1 : 0
        vignetteIntensity += (vignetteTarget - vignetteIntensity)
            * min(1, deltaTime / Self.vignetteFadeTime)

        applyTransform()
    }

    private func applyTransform() {
        guard let worldRoot else { return }
        var transform = entryTransform
        transform.translation += horizontalOffset - SIMD3<Float>(0, smoothedAltitude, 0)
        worldRoot.transform = transform
        distanceFromEntry = simd_length(horizontalOffset)
    }

    /// A single short step, for input that can't drag: VoiceOver's adjustable actions and Full
    /// Keyboard Access. Worth a quarter-second of travel at the current speed, which is a stride.
    ///
    /// - Parameter forward: 1 for a step ahead, −1 for a step back.
    func step(forward: Float) {
        guard worldRoot != nil else { return }
        horizontalOffset -= velocity(for: SIMD2<Float>(0, -forward)) * 0.25
        applyTransform()
    }

    /// The velocity the puck is asking for, in the wearer's current frame of reference.
    ///
    /// Yaw only, so pushing forward never drifts up or down with the angle of the head — looking
    /// down at the floor while travelling forward should not fly you into it.
    private func velocity(for input: SIMD2<Float>) -> SIMD3<Float> {
        let up = SIMD3<Float>(0, 1, 0)
        let forward = viewerFrame().forward
        let right = simd_normalize(simd_cross(forward, up))
        // The puck's y grows downward, as screen coordinates do; forward is up on the pad.
        let heading = right * input.x - forward * input.y
        guard simd_length(heading) > 0.001 else { return .zero }
        return simd_normalize(heading) * Self.baseSpeed * speed.multiplier
    }

    /// Keeps the puck's output inside the unit disc, so a diagonal push isn't 1.41× as fast as a
    /// straight one.
    private static func clampedToUnitDisc(_ input: SIMD2<Float>) -> SIMD2<Float> {
        let length = simd_length(input)
        guard length > 1 else { return input }
        return input / length
    }
}
