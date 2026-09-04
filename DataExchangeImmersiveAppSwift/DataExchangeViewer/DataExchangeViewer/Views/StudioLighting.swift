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

    static func makeEnvironment() async throws -> EnvironmentResource {
        try await EnvironmentResource(equirectangular: neutralEnvironmentImage)
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
    private static let neutralEnvironmentImage: CGImage = {
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
            fatalError("Failed to create the neutral lighting environment.")
        }

        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else {
            fatalError("Failed to render the neutral lighting environment.")
        }
        return image
    }()
}
