//
//  ComfortVignette.swift
//  DataExchangeViewer
//

import Foundation
import RealityKit
import CoreGraphics
import UIKit
import simd

/// A head-locked edge vignette, faded in while the world is translating.
///
/// Darkening the periphery during virtual locomotion reduces the mismatch between what the eyes
/// report (motion) and what the vestibular system reports (none). It is the cheapest of the
/// standard comfort mitigations and the one with the most evidence behind it, which is why it is
/// treated here as part of the feature rather than as polish.
///
/// Head-locked by updating its pose from the device anchor each frame, because visionOS exposes no
/// camera entity to parent to. Depth testing is off so it always draws over the model — a vignette
/// that the geometry can poke through is worse than none.
@MainActor
final class ComfortVignette {
    /// How far in front of the eyes the overlay sits, in meters. Close enough that only geometry
    /// practically touching the wearer's face can come between it and them.
    static let distance: Float = 0.32

    /// Size of the quad at that distance. Generous, so the vignette's dark edge stays outside the
    /// display's own edge and reads as peripheral shading rather than as a visible frame.
    static let size: Float = 0.9

    /// Peak opacity at full travel. Subtle on purpose: enough to catch the periphery, not enough to
    /// be mistaken for the model going dark.
    static let maximumOpacity: Float = 0.55

    private(set) var entity: Entity?

    /// Builds the overlay, or returns nil if its texture couldn't be created — in which case
    /// locomotion still works and simply has no vignette, which is the right degradation.
    func makeEntity() -> Entity? {
        if let entity { return entity }
        guard let image = Self.radialFalloffImage,
              let texture = try? TextureResource(
                  image: image,
                  withName: "comfort-vignette",
                  options: .init(semantic: .color)
              ) else {
            return nil
        }

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: 1.0)
        // Always on top: the overlay is a property of the display, not of the scene.
        material.readsDepth = false
        material.writesDepth = false
        material.faceCulling = .none

        let plane = ModelEntity(
            mesh: .generatePlane(width: Self.size, height: Self.size),
            materials: [material]
        )
        plane.name = "comfortVignette"
        // Starts fully transparent; `setIntensity` is what ever makes it visible.
        plane.components.set(OpacityComponent(opacity: 0))
        entity = plane
        return plane
    }

    /// Keeps the overlay in front of the eyes. Fully head-locked — including pitch, unlike the
    /// locomotion controls — because peripheral shading has to stay in the periphery when someone
    /// looks down at the floor they are flying over.
    func update(devicePose: Transform?, intensity: Float) {
        guard let entity else { return }
        guard let devicePose else {
            entity.isEnabled = false
            return
        }

        let opacity = min(max(intensity, 0), 1) * Self.maximumOpacity
        entity.isEnabled = opacity > 0.001
        entity.components.set(OpacityComponent(opacity: opacity))

        let forward = -SIMD3<Float>(
            devicePose.matrix.columns.2.x,
            devicePose.matrix.columns.2.y,
            devicePose.matrix.columns.2.z
        )
        entity.orientation = devicePose.rotation
        entity.position = devicePose.translation + forward * Self.distance
    }

    /// Transparent at the centre, opaque black at the corners.
    ///
    /// The falloff starts over halfway out so that the whole central field is untouched: the point
    /// is to remove peripheral optic flow, and dimming anything someone is actually looking at
    /// would be a worse trade than the motion it is meant to settle.
    private static let radialFalloffImage: CGImage? = {
        let side = 256
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let colors = [
            UIColor(white: 0, alpha: 0).cgColor,
            UIColor(white: 0, alpha: 0).cgColor,
            UIColor(white: 0, alpha: 1).cgColor
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.55, 1]
        ) else {
            return nil
        }

        let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        context.drawRadialGradient(
            gradient,
            startCenter: centre,
            startRadius: 0,
            endCenter: centre,
            // Out to the corner, so the four corners reach full opacity rather than clipping early.
            endRadius: CGFloat(side) / 2 * 1.414,
            options: [.drawsAfterEndLocation]
        )

        return context.makeImage()
    }()
}
