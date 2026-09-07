//
//  FlightController.swift
//  DataExchangeViewer
//

import Foundation
import SwiftUI
import RealityKit
import simd

/// Continuous virtual locomotion for Enter mode.
///
/// Flight used to move the model a fixed 0.3 m per button press, relying on
/// `.buttonRepeatBehavior(.enabled)` for anything longer. Traversing a 60 m building that way is
/// roughly 200 discrete jumps at a system-defined repeat rate, and the motion reads as stuttering
/// teleports rather than travel — which is also worse for comfort than smooth movement. This
/// applies a *velocity* for as long as a control is held, eases it in and out, and derives that
/// velocity from the size of the model so an interior and a whole site each take a sensible
/// amount of time to cross.
@Observable
final class FlightController {
    /// How fast to travel, as a multiplier on the model-derived base speed. Model size alone
    /// can't tell inspecting an interior apart from covering a site, so the multiplier stays
    /// under the wearer's control.
    enum Speed: CaseIterable, Identifiable {
        case walk
        case brisk
        case fast

        var id: Self { self }

        var title: String {
            switch self {
            case .walk: "Walk"
            case .brisk: "Brisk"
            case .fast: "Fast"
            }
        }

        var multiplier: Float {
            switch self {
            case .walk: 0.5
            case .brisk: 1
            case .fast: 4
            }
        }
    }

    enum Direction: Hashable {
        case forward
        case backward
        case left
        case right
        case up
        case down
    }

    var speed: Speed = .brisk

    /// The entity being flown through. Nil whenever Enter isn't presenting a model, which is also
    /// what keeps the per-frame update from doing any work.
    private var target: Entity?
    /// Scene units per second at a multiplier of 1, derived from the model's extents.
    private var baseSpeed = FlightController.minimumBaseSpeed
    private var heldDirections: Set<Direction> = []
    /// Directions whose press hasn't been accounted for by `nudge` yet. See `nudge`.
    private var pressedDirections: Set<Direction> = []
    private var velocity: SIMD3<Float> = .zero
    private var viewerForward: () -> SIMD3<Float> = { SIMD3<Float>(0, 0, -1) }
    private var updateSubscription: EventSubscription?

    /// Time constant for easing in and out: short enough that the controls feel responsive, long
    /// enough that starting and stopping isn't a jolt.
    private static let accelerationTime: Float = 0.25
    /// Below this the model is effectively stationary, so the update stops touching its transform
    /// rather than nudging it by fractions of a millimetre every frame.
    private static let restingSpeed: Float = 0.001
    /// Roughly how long one traversal of the model should take at a multiplier of 1. A 60 m
    /// building lands near brisk walking pace; a kilometre-wide site gets tens of metres a second.
    private static let secondsToCrossModel: Float = 30
    private static let minimumBaseSpeed: Float = 0.5
    private static let maximumBaseSpeed: Float = 25

    /// Starts the per-frame update. Called from `RealityView`'s `make` closure, which runs once,
    /// so the subscription is created once for the life of the scene.
    ///
    /// `viewerForward` is read every frame rather than captured at press time, so someone can
    /// steer by turning their head while still holding a direction.
    func attach(to content: RealityViewContent, viewerForward: @escaping () -> SIMD3<Float>) {
        self.viewerForward = viewerForward
        updateSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.step(deltaTime: Float(event.deltaTime))
        }
    }

    /// Points the controller at the model Enter is showing. `span` is the model's largest extent
    /// *in scene units* — its authored extents times whatever scale Enter chose — because that,
    /// not the authored size, is the distance someone actually has to cover.
    ///
    /// Pass nil when leaving Enter, or when the model is unloaded, to bring flight to a stop.
    func setTarget(_ entity: Entity?, span: Float = 0) {
        target = entity
        halt()
        baseSpeed = entity == nil
            ? Self.minimumBaseSpeed
            : min(max(span / Self.secondsToCrossModel, Self.minimumBaseSpeed), Self.maximumBaseSpeed)
    }

    /// Brings flight to a stop while keeping the target. Called before an animated move of the
    /// same entity, which would otherwise be fighting the per-frame velocity for one transform.
    func halt() {
        heldDirections = []
        pressedDirections = []
        velocity = .zero
    }

    func hold(_ direction: Direction) {
        heldDirections.insert(direction)
        pressedDirections.insert(direction)
    }

    func release(_ direction: Direction) {
        heldDirections.remove(direction)
    }

    /// A single short move, worth one acceleration period of travel at the current speed.
    ///
    /// This is a flight button's `action`, which SwiftUI also runs when a press-and-hold ends —
    /// and that press has already flown the model, so moving again would put a small jump at the
    /// end of every hold. Recording the press in `hold` and consuming it here leaves the nudge
    /// for the activations that report no press at all: VoiceOver and Full Keyboard Access.
    func nudge(_ direction: Direction) {
        let wasPressed = pressedDirections.remove(direction) != nil
        guard let target, !wasPressed else { return }
        target.position -= velocity(towards: [direction]) * Self.accelerationTime
    }

    /// Applies the current velocity for one frame. Returns immediately once nothing is held and
    /// the model has come to rest, so an idle Enter session costs one comparison per frame.
    private func step(deltaTime: Float) {
        guard let target, deltaTime > 0 else { return }

        let desired = velocity(towards: heldDirections)
        if desired == .zero, simd_length(velocity) < Self.restingSpeed {
            velocity = .zero
            return
        }

        // Exponential approach to the desired velocity: one expression that eases in while a
        // control is held and eases out when it's released, with no animation to start or cancel.
        velocity += (desired - velocity) * min(1, deltaTime / Self.accelerationTime)

        // The wearer is the camera on visionOS, so virtual locomotion moves the world opposite
        // the intended direction of travel.
        target.position -= velocity * deltaTime
    }

    /// The velocity that holding `directions` asks for, in the wearer's current frame of
    /// reference. Yaw only, so flying forward never drifts up or down with the angle of the head.
    private func velocity(towards directions: Set<Direction>) -> SIMD3<Float> {
        guard !directions.isEmpty else { return .zero }

        let up = SIMD3<Float>(0, 1, 0)
        let forward = viewerForward()
        let right = simd_normalize(simd_cross(forward, up))

        var heading = SIMD3<Float>.zero
        for direction in directions {
            switch direction {
            case .forward: heading += forward
            case .backward: heading -= forward
            case .left: heading -= right
            case .right: heading += right
            case .up: heading += up
            case .down: heading -= up
            }
        }

        // Opposing directions held together cancel out, and normalizing that would divide by zero.
        guard simd_length(heading) > 0.001 else { return .zero }
        return simd_normalize(heading) * baseSpeed * speed.multiplier
    }
}
