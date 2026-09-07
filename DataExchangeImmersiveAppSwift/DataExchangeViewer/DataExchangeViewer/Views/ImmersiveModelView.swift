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
    /// Degradations rather than failures: the model is on screen and usable, but something it
    /// depends on didn't come up. Reported so an unlit model or an unsteerable flight reads as a
    /// known limitation and not as broken geometry or broken controls.
    @State private var notices: [Notice: String] = [:]
    @State private var arkitSession = ARKitSession()
    @State private var worldTracking = WorldTrackingProvider()
    @State private var flight = FlightController()

    private static let manipulationHintKey = "hasSeenPlacedModelManipulationHint"
    @AppStorage(Self.manipulationHintKey) private var hasSeenManipulationHint = false
    @State private var showManipulationHint = false

    var body: some View {
        RealityView { content in
            root.addChild(backgroundContainer)
            root.addChild(modelContainer)
            content.add(root)

            do {
                StudioLighting.apply(
                    try await StudioLighting.makeEnvironment(),
                    to: root,
                    withBackground: false
                )
            } catch {
                notices[.lighting] =
                    "Studio lighting is unavailable, so this model is rendering unlit. \(error.userFacingDescription)"
            }
            backgroundContainer.addChild(StudioLighting.makeBackgroundEntity())

            // `make` runs once, so flight subscribes to the scene update exactly once. The
            // provider is captured directly rather than through `self` so the closure doesn't
            // depend on a view struct that SwiftUI re-creates on every invalidation.
            let tracking = worldTracking
            flight.attach(to: content) { Self.viewerForward(from: tracking) }
        } update: { _ in
            backgroundContainer.isEnabled = appModel.selectedPreviewMode == .enter

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
                } else if showManipulationHint && appModel.selectedPreviewMode == .place {
                    Label("Pinch and drag to move; use two hands to rotate or resize", systemImage: "hand.pinch")
                        .padding()
                        .glassBackgroundEffect()
                        .transition(.opacity)
                }

                ForEach(Notice.allCases, id: \.self) { notice in
                    if let message = notices[notice] {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .glassBackgroundEffect()
                    }
                }

                PreviewModePicker(
                    fileURL: appModel.previewModelURL,
                    modelName: appModel.previewModelName ?? "Model"
                )

                if appModel.selectedPreviewMode == .enter {
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
        .task(id: appModel.selectedPreviewMode) {
            guard appModel.selectedPreviewMode == .place, !hasSeenManipulationHint else { return }
            withAnimation { showManipulationHint = true }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showManipulationHint = false }
            // `try?` swallows cancellation, so leaving Place inside the four-second window used
            // to fall straight through to here and retire the hint after it had been on screen
            // for a fraction of a second. Only a full showing counts as having seen it.
            guard !Task.isCancelled else { return }
            hasSeenManipulationHint = true
        }
        .onChange(of: appModel.selectedPreviewMode) { oldMode, newMode in
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
            if appModel.selectedPreviewMode == .place, let loadedEntity {
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
            guard appModel.selectedPreviewMode == .enter, let loadedEntity else { return }
            // The animated move below and the per-frame flight update write the same transform.
            flight.halt()
            let deviceTransform = await currentDeviceTransform()
            loadedEntity.move(
                to: ModelPlacement.enteredTransform(
                    bounds: loadedEntity.visualBounds(relativeTo: loadedEntity),
                    relativeTo: deviceTransform
                ),
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
        return ModelPlacement.viewerFrame(from: transform).forward
    }

    @MainActor
    private func startWorldTracking() async {
        // A platform without world tracking is a capability, not a failure, and there is nothing
        // the person could do about it — so it stays silent, as before.
        guard WorldTrackingProvider.isSupported, worldTracking.state != .running else { return }
        do {
            try await arkitSession.run([worldTracking])
            notices[.tracking] = nil
        } catch {
            // Not fatal: `viewerFrame` falls back to visionOS's conventional initial immersive
            // frame, so the model still appears and flight still moves it. What's lost is the
            // heading, which is what lets someone steer mid-flight by turning their head — so a
            // silent fallback would read as broken controls.
            notices[.tracking] = """
            Head tracking didn't start, so the model is positioned from a default viewpoint and \
            flight can't be steered by turning your head. \(error.userFacingDescription)
            """
        }
    }

    /// One slot per degradation, so re-running the load replaces a message rather than appending
    /// another copy of it.
    private enum Notice: CaseIterable {
        case lighting
        case tracking
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
            apply(appModel.selectedPreviewMode, to: entity, relativeTo: deviceTransform, animated: false)
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
            let bounds = entity.visualBounds(relativeTo: entity)
            target = appModel.placedModelTransform
                ?? ModelPlacement.placedTransform(bounds: bounds, relativeTo: deviceTransform)
                ?? entity.transform
            ManipulationComponent.configureEntity(entity)
            if var manipulation = entity.components[ManipulationComponent.self] {
                manipulation.releaseBehavior = .stay
                entity.components.set(manipulation)
            }

        case .enter:
            entity.components.remove(ManipulationComponent.self)
            let bounds = entity.visualBounds(relativeTo: entity)
            let entered = ModelPlacement.enteredTransform(bounds: bounds, relativeTo: deviceTransform)
            target = entered
            // Flight speed follows the size the model will have in the scene, so it's the local
            // extents times the scale Enter just chose. Read from the target transform rather
            // than from world bounds, which the move below may not have applied yet.
            let extents = bounds.extents
            flight.setTarget(entity, span: max(extents.x, extents.y, extents.z) * entered.scale.x)
        }

        if animated {
            entity.move(to: target, relativeTo: entity.parent, duration: 0.45, timingFunction: .easeInOut)
        } else {
            entity.transform = target
        }
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
