//
//  StudioLighting.swift
//  DataExchangeViewer
//

import RealityKit
import CoreGraphics
import UIKit

/// Provides neutral lighting and a plain backdrop for previewed USDZ models.
enum StudioLighting {
    /// Radius of the visible background sphere, in meters. Exposed so callers can size content
    /// to stay comfortably within it instead of poking through its surface.
    // Enter can contain building-scale geometry placed in front of the wearer. Keep the backdrop
    // comfortably beyond that content so its surface never becomes a clipping boundary.
    static let backgroundSphereRadius: Float = 500

    enum LightingError: Error {
        /// The generated neutral environment bitmap could not be created.
        case environmentImageUnavailable
    }

    static func makeEnvironment() async throws -> EnvironmentResource {
        guard let image = neutralEnvironmentImage else {
            throw LightingError.environmentImageUnavailable
        }
        return try await EnvironmentResource(equirectangular: image)
    }

    /// Adds uniform image-based light so PBR materials remain legible without suggesting a
    /// particular physical environment. Peek also receives the white backdrop here; Enter owns
    /// the same backdrop separately so Place can keep passthrough visible.
    static func apply(_ environment: EnvironmentResource, to root: Entity, withBackground: Bool = true) {
        let lightEntity = Entity()
        var component = ImageBasedLightComponent(source: .single(environment))
        component.inheritsRotation = true
        lightEntity.components.set(component)
        root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lightEntity))
        root.addChild(lightEntity)

        if withBackground {
            root.addChild(makeBackgroundEntity())
        }
    }

    /// Creates the plain backdrop separately so the shared immersive scene can show it for Enter
    /// and hide it for mixed-space Place.
    static func makeBackgroundEntity() -> ModelEntity {
        var material = UnlitMaterial()
        material.color = .init(tint: .white)
        material.faceCulling = .none
        return ModelEntity(mesh: .generateSphere(radius: backgroundSphereRadius), materials: [material])
    }

    /// A tiny, generated 2:1 map supplies shadow-free white IBL without bundling or displaying
    /// a photographic environment image.
    /// Optional rather than force-created: callers already treat a missing environment as
    /// "render without image-based lighting", which is a far better outcome than trapping.
    private static let neutralEnvironmentImage: CGImage? = {
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

        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage()
    }()
}
