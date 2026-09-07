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
    @State private var flight = FlightController()

    /// Caps exceptionally large source geometry independently of the backdrop size. Since the
    /// model's nearest face is placed in front of the wearer, its farthest face can be roughly
    /// twice this distance away; 150 m leaves ample clearance inside the 500 m white sphere.
    private static let maximumEnteredModelReach: Float = 150
    /// Scales small geometry up instead. Entering a 20 cm mechanical part at authored scale left
    /// a 20 cm object floating two metres away inside a white sphere with nothing to fly through,
    /// so Enter was effectively a no-op below room scale. Four metres is small enough to take in
    /// at a glance and large enough to move around inside.
    private static let minimumEnteredModelReach: Float = 4
    private static let manipulationHintKey = "hasSeenPlacedModelManipulationHint"
    @AppStorage(Self.manipulationHintKey) private var hasSeenManipulationHint = false
    @State private var showManipulationHint = false

    var body: some View {
        RealityView { content in
            root.addChild(backgroundContainer)
            root.addChild(modelContainer)
            content.add(root)

            if let environment = try? await StudioLighting.makeEnvironment() {
                StudioLighting.apply(environment, to: root, withBackground: false)
            }
            backgroundContainer.addChild(StudioLighting.makeBackgroundEntity())

            // `make` runs once, so flight subscribes to the scene update exactly once. The
            // provider is captured directly rather than through `self` so the closure doesn't
            // depend on a view struct that SwiftUI re-creates on every invalidation.
            let tracking = worldTracking
            flight.attach(to: content) { Self.viewerForward(from: tracking) }
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
            await loadModel()
        }
        .task(id: appModel.activeMode) {
            guard appModel.activeMode == .place, !hasSeenManipulationHint else { return }
            withAnimation { showManipulationHint = true }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showManipulationHint = false }
            // `try?` swallows cancellation, so leaving Place inside the four-second window used
            // to fall straight through to here and retire the hint after it had been on screen
            // for a fraction of a second. Only a full showing counts as having seen it.
            guard !Task.isCancelled else { return }
            hasSeenManipulationHint = true
        }
        .onChange(of: appModel.activeMode) { oldMode, newMode in
            guard let loadedEntity else { return }
            Task { @MainActor in
                appModel.beginModeSwitch()
                defer { appModel.endModeSwitch() }
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
            flight.setTarget(nil)
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

            speedPicker
        }
        .padding(10)
        .glassBackgroundEffect()
    }

    /// The model's own size sets the base speed, but what someone wants differs between
    /// inspecting an interior and covering a site, so the multiplier stays their choice.
    private var speedPicker: some View {
        Picker("Speed", selection: $flight.speed) {
            ForEach(FlightController.Speed.allCases) { speed in
                Text(speed.title).tag(speed)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Flight speed")
    }

    private func flightButton(
        _ title: String,
        systemImage: String,
        direction: FlightController.Direction
    ) -> some View {
        Button {
            // Only reached by an activation that reported no press — see `FlightController.nudge`.
            flight.nudge(direction)
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(HoldToFlyButtonStyle { isPressed in
            if isPressed {
                flight.hold(direction)
            } else {
                flight.release(direction)
            }
        })
        .accessibilityHint("Hold to fly continuously, or activate once to move a short step")
    }

    private func resetEntrance() {
        Task { @MainActor in
            guard appModel.activeMode == .enter, let loadedEntity else { return }
            // The animated move below and the per-frame flight update write the same transform.
            flight.halt()
            let deviceTransform = await currentDeviceTransform()
            loadedEntity.move(
                to: Self.enteredTransform(for: loadedEntity, relativeTo: deviceTransform),
                relativeTo: loadedEntity.parent,
                duration: 0.35,
                timingFunction: .easeInOut
            )
        }
    }

    /// The wearer's current heading, read straight from the device anchor. Cheap enough to call
    /// once a frame, which is what lets someone steer mid-flight by turning their head.
    private static func viewerForward(from provider: WorldTrackingProvider) -> SIMD3<Float> {
        let transform = provider
            .queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
            .flatMap { $0.isTracked ? Transform(matrix: $0.originFromAnchorTransform) : nil }
        return viewerFrame(from: transform).forward
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
        // Nothing to fly through until the replacement finishes loading.
        flight.setTarget(nil)
        guard let fileURL = appModel.previewModelURL else { return }

        // ARKit session startup and reading the model are independent, so they run concurrently
        // rather than serializing the file load behind the session. Both have to finish before
        // the placement transform can be computed, since that needs the device pose.
        async let session: Void = startWorldTracking()
        async let model = USDzEntityCache.shared.entity(at: fileURL)

        do {
            let entity = try await model
            await session
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
        // Flight belongs to Enter alone, and every Enter recomputes it below, so this leaves the
        // controller holding a model exactly while Enter owns the presentation.
        if mode != .enter {
            flight.setTarget(nil)
        }

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
            let entered = Self.enteredTransform(for: entity, relativeTo: deviceTransform)
            target = entered
            // Flight speed follows the size the model will have in the scene, so it's the local
            // extents times the scale Enter just chose. Read from the target transform rather
            // than from world bounds, which the move below may not have applied yet.
            let extents = entity.visualBounds(relativeTo: entity).extents
            flight.setTarget(entity, span: max(extents.x, extents.y, extents.z) * entered.scale.x)
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

    /// Brings the model to a scale someone can walk through, stands its lowest point on the
    /// floor, and places the nearest face two meters in front of the person so they begin
    /// outside the geometry. A building-sized model keeps its authored scale.
    private static func enteredTransform(
        for entity: Entity,
        relativeTo deviceTransform: Transform?
    ) -> Transform {
        let bounds = entity.visualBounds(relativeTo: entity)
        let halfWidth = bounds.extents.x / 2
        let halfDepth = bounds.extents.z / 2
        let height = bounds.extents.y
        let reach = (halfWidth * halfWidth + height * height + halfDepth * halfDepth).squareRoot()

        // Clamped in both directions: a site model is brought inside the backdrop, and anything
        // smaller than a room is scaled up to a size worth walking through. Only clamping
        // downwards made Enter a no-op for small parts.
        let scale: Float
        if reach < 0.0001 {
            scale = 1
        } else if reach < minimumEnteredModelReach {
            scale = minimumEnteredModelReach / reach
        } else if reach > maximumEnteredModelReach {
            scale = maximumEnteredModelReach / reach
        } else {
            scale = 1
        }
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

/// Reports its press state so flight can apply velocity for exactly as long as a control is held.
///
/// The flight buttons can't use `.buttonStyle(.bordered)` for this: a style's `isPressed` is the
/// platform's own press tracking, and nothing else reports the beginning *and* end of a
/// press-and-hold as reliably — which is the whole basis of holding to fly. It keeps
/// `.hoverEffect()`, because on Vision Pro hover is the targeting feedback for eye tracking, and
/// draws on a system material rather than a fixed color so it stays legible against passthrough.
private struct HoldToFlyButtonStyle: ButtonStyle {
    let onPressedChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3)
            .frame(width: 44, height: 44)
            .background(.thinMaterial, in: Circle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .hoverEffect()
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressedChange(isPressed)
            }
    }
}
