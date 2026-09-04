//
//  ImmersiveModelView.swift
//  DataExchangeViewer
//

import SwiftUI
import RealityKit
import ARKit
import QuartzCore
import simd

/// Owns the one spatial model scene used by both Place and Enter. Because the entity remains in
/// this scene while the immersion style changes, switching modes is immediate and the person's
/// tabletop placement can be restored after an architectural-scale walkthrough.
struct ImmersiveModelView: View {
    @Environment(AppModel.self) private var appModel

    @State private var root = Entity()
    @State private var modelContainer = Entity()
    @State private var backgroundContainer = Entity()
    @State private var loadedEntity: Entity?
    @State private var loadError: String?
    @State private var arkitSession = ARKitSession()
    @State private var worldTracking = WorldTrackingProvider()

    /// Caps exceptionally large source geometry independently of the backdrop size. Since the
    /// model's nearest face is placed in front of the wearer, its farthest face can be roughly
    /// twice this distance away; 150 m leaves ample clearance inside the 500 m white sphere.
    private static let maximumEnteredModelReach: Float = 150
    /// Small repeated steps feel continuous when a button is held, while a single press remains
    /// useful for precise positioning near walls and doorways.
    private static let flightStep: Float = 0.3
    private static let manipulationHintKey = "hasSeenPlacedModelManipulationHint"
    @AppStorage(Self.manipulationHintKey) private var hasSeenManipulationHint = false
    @State private var showManipulationHint = false

    private enum FlightDirection {
        case forward
        case backward
        case left
        case right
        case up
        case down
    }

    var body: some View {
        RealityView { content in
            root.addChild(backgroundContainer)
            root.addChild(modelContainer)
            content.add(root)

            if let environment = try? await StudioLighting.makeEnvironment() {
                StudioLighting.apply(environment, to: root, withBackground: false)
            }
            backgroundContainer.addChild(StudioLighting.makeBackgroundEntity())
        } update: { _ in
            backgroundContainer.isEnabled = appModel.activeMode == .enter

            if let loadedEntity {
                if loadedEntity.parent !== modelContainer {
                    modelContainer.children.removeAll()
                    modelContainer.addChild(loadedEntity)
                }
            } else {
                modelContainer.children.removeAll()
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            VStack(spacing: 12) {
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding()
                        .glassBackgroundEffect()
                } else if showManipulationHint && appModel.activeMode == .place {
                    Label("Pinch and drag to move; use two hands to rotate or resize", systemImage: "hand.pinch")
                        .padding()
                        .glassBackgroundEffect()
                        .transition(.opacity)
                }

                PreviewModePicker(
                    fileURL: appModel.previewModelURL,
                    modelName: appModel.previewModelName ?? "Model"
                )

                if appModel.activeMode == .enter {
                    flightControls

                    Button {
                        appModel.isFullImmersion.toggle()
                        appModel.immersionStyle = appModel.isFullImmersion
                            ? FullImmersionStyle()
                            : ProgressiveImmersionStyle()
                    } label: {
                        Label(
                            appModel.isFullImmersion ? "Use Progressive Immersion" : "Go Full Immersion",
                            systemImage: appModel.isFullImmersion
                                ? "circle.lefthalf.filled"
                                : "circle.fill"
                        )
                    }
                    .accessibilityHint(
                        appModel.isFullImmersion
                            ? "Restores the Digital Crown immersion control"
                            : "Fully replaces your surroundings with the model environment"
                    )
                }
            }
            .padding()
        }
        .task(id: appModel.previewModelURL) {
            await startWorldTracking()
            await loadModel()
        }
        .task(id: appModel.activeMode) {
            guard appModel.activeMode == .place, !hasSeenManipulationHint else { return }
            withAnimation { showManipulationHint = true }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showManipulationHint = false }
            hasSeenManipulationHint = true
        }
        .onChange(of: appModel.activeMode) { oldMode, newMode in
            guard let loadedEntity else { return }
            Task { @MainActor in
                appModel.isSwitchingMode = true
                defer { appModel.isSwitchingMode = false }
                await transition(loadedEntity, from: oldMode, to: newMode)
            }
        }
        .onAppear {
            appModel.immersiveSpaceState = .open
        }
        .onDisappear {
            if appModel.activeMode == .place, let loadedEntity {
                appModel.placedModelTransform = loadedEntity.transform
            }
            arkitSession.stop()
            appModel.immersiveSpaceDidClose()
        }
    }

    /// Progressive and full immersion have a system safety boundary around the wearer. These
    /// controls provide virtual locomotion by moving the model in the opposite direction, letting
    /// someone explore a large building while remaining comfortably in one physical location.
    private var flightControls: some View {
        VStack(spacing: 6) {
            Text("Stay in place — face a direction, then hold ↑ to fly")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                flightButton("Fly left", systemImage: "arrow.left", direction: .left)

                VStack(spacing: 6) {
                    flightButton("Fly forward", systemImage: "arrow.up", direction: .forward)
                    flightButton("Fly backward", systemImage: "arrow.down", direction: .backward)
                }

                flightButton("Fly right", systemImage: "arrow.right", direction: .right)

                Divider()
                    .frame(height: 54)

                VStack(spacing: 6) {
                    flightButton("Fly up", systemImage: "arrow.up.circle", direction: .up)
                    flightButton("Fly down", systemImage: "arrow.down.circle", direction: .down)
                }

                Divider()
                    .frame(height: 54)

                Button {
                    resetEntrance()
                } label: {
                    Label("Return to entrance", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .accessibilityHint("Returns you to the starting position outside the model")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .glassBackgroundEffect()
    }

    private func flightButton(
        _ title: String,
        systemImage: String,
        direction: FlightDirection
    ) -> some View {
        Button {
            fly(direction)
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonRepeatBehavior(.enabled)
        .accessibilityHint("Press and hold for continuous movement")
    }

    @MainActor
    private func fly(_ direction: FlightDirection) {
        guard appModel.activeMode == .enter, let loadedEntity else { return }

        let deviceTransform = worldTracking
            .queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
            .flatMap { $0.isTracked ? Transform(matrix: $0.originFromAnchorTransform) : nil }
        let viewer = Self.viewerFrame(from: deviceTransform)
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(viewer.forward, up))

        let travelDirection: SIMD3<Float>
        switch direction {
        case .forward:
            travelDirection = viewer.forward
        case .backward:
            travelDirection = -viewer.forward
        case .left:
            travelDirection = -right
        case .right:
            travelDirection = right
        case .up:
            travelDirection = up
        case .down:
            travelDirection = -up
        }

        // The wearer is the camera on visionOS, so virtual locomotion moves the world opposite
        // the intended direction of travel.
        loadedEntity.position -= travelDirection * Self.flightStep
    }

    private func resetEntrance() {
        Task { @MainActor in
            guard appModel.activeMode == .enter, let loadedEntity else { return }
            let deviceTransform = await currentDeviceTransform()
            loadedEntity.move(
                to: Self.enteredTransform(for: loadedEntity, relativeTo: deviceTransform),
                relativeTo: loadedEntity.parent,
                duration: 0.35,
                timingFunction: .easeInOut
            )
        }
    }

    @MainActor
    private func startWorldTracking() async {
        guard WorldTrackingProvider.isSupported, worldTracking.state != .running else { return }
        try? await arkitSession.run([worldTracking])
    }

    /// Device-anchor queries don't require world-sensing authorization. Waiting briefly gives the
    /// provider time to produce its first tracked pose immediately after the immersive space opens.
    @MainActor
    private func currentDeviceTransform() async -> Transform? {
        for _ in 0..<20 {
            if let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
               anchor.isTracked {
                return Transform(matrix: anchor.originFromAnchorTransform)
            }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return nil }
        }
        return nil
    }

    @MainActor
    private func loadModel() async {
        loadedEntity = nil
        loadError = nil
        guard let fileURL = appModel.previewModelURL else { return }

        do {
            let entity = try await Entity(contentsOf: fileURL)
            if let modelName = appModel.previewModelName {
                entity.isAccessibilityElement = true
                entity.accessibilityLabelKey = LocalizedStringResource("\(modelName)")
            }
            let deviceTransform = await currentDeviceTransform()
            apply(appModel.activeMode, to: entity, relativeTo: deviceTransform, animated: false)
            loadedEntity = entity
        } catch {
            loadError = "Failed to load preview: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func transition(
        _ entity: Entity,
        from oldMode: AppModel.PreviewMode,
        to newMode: AppModel.PreviewMode
    ) async {
        if oldMode == .place {
            appModel.placedModelTransform = entity.transform
        }
        let deviceTransform = await currentDeviceTransform()
        apply(newMode, to: entity, relativeTo: deviceTransform, animated: oldMode != .peek)
    }

    private func apply(
        _ mode: AppModel.PreviewMode,
        to entity: Entity,
        relativeTo deviceTransform: Transform?,
        animated: Bool
    ) {
        let target: Transform

        switch mode {
        case .peek:
            return

        case .place:
            target = appModel.placedModelTransform
                ?? Self.defaultPlacedTransform(for: entity, relativeTo: deviceTransform)
            ManipulationComponent.configureEntity(entity)
            if var manipulation = entity.components[ManipulationComponent.self] {
                manipulation.releaseBehavior = .stay
                entity.components.set(manipulation)
            }

        case .enter:
            entity.components.remove(ManipulationComponent.self)
            target = Self.enteredTransform(for: entity, relativeTo: deviceTransform)
        }

        if animated {
            entity.move(to: target, relativeTo: entity.parent, duration: 0.45, timingFunction: .easeInOut)
        } else {
            entity.transform = target
        }
    }

    /// Places the model's center at a comfortable tabletop height and scales its largest dimension
    /// to 65 cm, leaving it close enough for direct hand interaction.
    private static func defaultPlacedTransform(
        for entity: Entity,
        relativeTo deviceTransform: Transform?
    ) -> Transform {
        let bounds = entity.visualBounds(relativeTo: entity)
        let maxDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard maxDimension > 0 else { return entity.transform }

        let scale: Float = 0.65 / maxDimension
        let viewer = viewerFrame(from: deviceTransform)
        let rotation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: viewer.forward)
        let desiredCenter = viewer.position + viewer.forward * 1.2 + SIMD3<Float>(0, -0.25, 0)
        let scaledCenter = rotation.act(bounds.center * scale)
        return Transform(
            scale: SIMD3<Float>(repeating: scale),
            rotation: rotation,
            translation: desiredCenter - scaledCenter
        )
    }

    /// Keeps the building near authored scale, stands its lowest point on the floor, and places
    /// the nearest face two meters in front of the person so they begin outside the geometry.
    private static func enteredTransform(
        for entity: Entity,
        relativeTo deviceTransform: Transform?
    ) -> Transform {
        let bounds = entity.visualBounds(relativeTo: entity)
        let halfWidth = bounds.extents.x / 2
        let halfDepth = bounds.extents.z / 2
        let height = bounds.extents.y
        let reach = (halfWidth * halfWidth + height * height + halfDepth * halfDepth).squareRoot()
        let scale = reach > maximumEnteredModelReach ? maximumEnteredModelReach / reach : 1
        let viewer = viewerFrame(from: deviceTransform)
        let rotation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: viewer.forward)

        // Put the center of the model's nearest face two meters ahead of the wearer. The y
        // translation remains floor-relative so the building stays upright and grounded.
        let desiredFront = viewer.position + viewer.forward * 2
        let localFront = SIMD3<Float>(bounds.center.x, 0, bounds.center.z + halfDepth) * scale
        let rotatedFront = rotation.act(localFront)

        return Transform(
            scale: SIMD3<Float>(repeating: scale),
            rotation: rotation,
            translation: SIMD3<Float>(
                desiredFront.x - rotatedFront.x,
                -bounds.min.y * scale,
                desiredFront.z - rotatedFront.z
            )
        )
    }

    /// Uses only the wearer's yaw so buildings remain vertical even when the person looks up or
    /// down. The fallback matches visionOS's conventional initial immersive coordinate frame.
    private static func viewerFrame(from transform: Transform?) -> (position: SIMD3<Float>, forward: SIMD3<Float>) {
        guard let transform else {
            return (SIMD3<Float>(0, 1.6, 0), SIMD3<Float>(0, 0, -1))
        }

        let forward3D = -transform.matrix.columns.2
        let horizontal = SIMD3<Float>(forward3D.x, 0, forward3D.z)
        let length = simd_length(horizontal)
        let forward = length > 0.001 ? horizontal / length : SIMD3<Float>(0, 0, -1)
        return (transform.translation, forward)
    }
}
