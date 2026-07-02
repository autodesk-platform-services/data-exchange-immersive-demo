//
//  StudioLighting.swift
//  DataExchangeViewer
//

import RealityKit
import CoreGraphics
import ImageIO
import UIKit

/// Lights previewed USDZ models with a bundled HDRI so they read as lit objects in a
/// real environment instead of floating in an unlit void.
enum StudioLighting {
    /// Radius of the visible background sphere, in meters. Exposed so callers can size content
    /// to stay comfortably within it instead of poking through its surface.
    static let backgroundSphereRadius: Float = 50

    static func makeEnvironment() async throws -> EnvironmentResource {
        try await EnvironmentResource(equirectangular: environmentImage)
    }

    /// Adds an image-based light sourced from `environment` so entities added under `root` are lit,
    /// and — when `withBackground` is true — a large inward-facing sphere textured with the same
    /// HDRI so the environment is visible as a backdrop instead of an empty void.
    static func apply(_ environment: EnvironmentResource, to root: Entity, withBackground: Bool = true) throws {
        let lightEntity = Entity()
        var component = ImageBasedLightComponent(source: .single(environment))
        component.inheritsRotation = true
        lightEntity.components.set(component)
        root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lightEntity))
        root.addChild(lightEntity)

        if withBackground {
            root.addChild(try makeBackgroundSphere())
        }
    }

    private static func makeBackgroundSphere() throws -> ModelEntity {
        let texture = try TextureResource(image: environmentImage, options: .init(semantic: .color))
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.faceCulling = .none
        return ModelEntity(mesh: .generateSphere(radius: backgroundSphereRadius), materials: [material])
    }

    /// The bundled equirectangular HDRI, used both to light previewed models and as their
    /// visible backdrop. Loaded once and cached, since it's a large 4K image.
    private static let environmentImage: CGImage = {
        guard
            let url = Bundle.main.url(forResource: "golden_gate_hills_4k", withExtension: "exr"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            fatalError("Failed to load the bundled environment map.")
        }
        return image
    }()
}
