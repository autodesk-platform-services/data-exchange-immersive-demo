//
//  PreviewEnvironment.swift
//  DataExchangeViewer
//

import RealityKit
import CoreGraphics
import UIKit

/// The lighting and backdrop a previewed model is shown against.
///
/// Both Portal and Immersive replace the room entirely — a portal world inherits neither the
/// passthrough nor the room's lighting, and full immersion has nothing behind the model at all — so
/// each needs an environment of its own or the model renders as an unlit silhouette against black.
///
/// The pairing here is deliberate. The IBL is low and *graded* rather than flat, so a horizontal
/// surface and a vertical one catch different amounts of it and the model's form reads; under the
/// current grading the geometry itself comes out dark, so the backdrop is white to keep the
/// silhouette legible against it.
enum PreviewEnvironment {
    /// Backdrop colour. White, for contrast against geometry that the graded IBL leaves dark — an
    /// unlit white sphere is the brightest thing in the scene, so if full immersion reads as glare
    /// this is the value to pull down towards off-white.
    static let backdropColor = UIColor.white

    /// Radius of the Immersive backdrop, in meters. Comfortably beyond any building-scale model at
    /// 1:1 so its surface never becomes a visible clipping boundary as someone flies outward.
    static let immersiveBackdropRadius: Float = 500

    /// Half-extent of the Portal backdrop, in meters. Small, because it only has to fill the
    /// portal's own clipping volume, and a 500 m sphere inside a 40 cm portal is 500 m of depth
    /// buffer spent on a box someone sees 40 cm of.
    static let portalBackdropRadius: Float = 2

    /// Power-of-two exponent applied to the image-based light. Negative dims it: −1.5 is a little
    /// over a third of the map's nominal intensity, enough to shade white geometry without
    /// blowing it out.
    static let intensityExponent: Float = -1.5

    enum LightingError: Error {
        /// The generated environment bitmap could not be created.
        case environmentImageUnavailable
    }

    static func makeEnvironment() async throws -> EnvironmentResource {
        guard let image = gradientEnvironmentImage else {
            throw LightingError.environmentImageUnavailable
        }
        return try await EnvironmentResource(equirectangular: image)
    }

    /// Adds the image-based light to `root`, so everything under it is lit by the same environment.
    ///
    /// The light lives on a child entity referenced by an `ImageBasedLightReceiverComponent`, which
    /// is what scopes it to this subtree instead of the whole scene — Portal's world and the room
    /// around the window are different lighting environments on purpose.
    static func applyLighting(_ environment: EnvironmentResource, to root: Entity) {
        let lightEntity = Entity()
        lightEntity.name = "ibl"
        var component = ImageBasedLightComponent(
            source: .single(environment),
            intensityExponent: intensityExponent
        )
        // The environment turns with the content rather than the wearer's head, so the gradient
        // stays fixed relative to the model and its shading doesn't slide as someone looks around.
        component.inheritsRotation = true
        lightEntity.components.set(component)
        root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lightEntity))
        root.addChild(lightEntity)
    }

    /// An inward-facing, unlit backdrop.
    ///
    /// Unlit on purpose: a lit backdrop would pick up the IBL and shade top-to-bottom with it,
    /// turning an even white enclosure into a visibly graded grey one.
    static func makeBackdrop(radius: Float) -> ModelEntity {
        var material = UnlitMaterial()
        material.color = .init(tint: backdropColor)
        // Seen from the inside, so the outward-facing half of the sphere has to survive culling.
        material.faceCulling = .none
        let backdrop = ModelEntity(mesh: .generateSphere(radius: radius), materials: [material])
        backdrop.name = "backdrop"
        return backdrop
    }

    /// A small 2:1 equirectangular map, generated rather than bundled.
    ///
    /// A vertical gradient, not a flat fill. Flat light gives every surface of a single-colour
    /// model the same value and the whole thing reads as one flat shape — a sky-to-ground gradient
    /// means a horizontal surface and a vertical one catch different amounts of it, and the
    /// model's form comes back.
    ///
    /// Optional rather than force-created: callers already treat a missing environment as "render
    /// without image-based lighting", which is a far better outcome than trapping.
    private static let gradientEnvironmentImage: CGImage? = {
        let width = 32
        let height = 16
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Neutral throughout — a tinted environment would recolour the model's materials, and
        // these are engineering models whose colours mean something.
        let colors = [
            UIColor(white: 0.62, alpha: 1).cgColor,
            UIColor(white: 0.30, alpha: 1).cgColor,
            UIColor(white: 0.10, alpha: 1).cgColor
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.55, 1]
        ) else {
            return nil
        }

        // Row 0 of an equirectangular map is the zenith, so the gradient runs top to bottom.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: 0, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        return context.makeImage()
    }()
}
