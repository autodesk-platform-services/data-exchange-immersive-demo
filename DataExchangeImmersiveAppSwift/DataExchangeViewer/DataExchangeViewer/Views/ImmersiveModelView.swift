//
//  ImmersiveModelView.swift
//  DataExchangeViewer
//

import SwiftUI
import RealityKit
import ARKit
import QuartzCore
import simd

/// Immersive mode: the model at 1:1 in a full immersive space, walked through with on-screen
/// locomotion controls.
///
/// The rig is the whole idea. visionOS has no API to move the person, so "stand the user in the
/// middle of the design" is done by moving a *world* entity that holds the model: on entry it is
/// positioned so the model's entry point lands at the wearer's feet, and every subsequent
/// "movement" is that entity translating the opposite way. The wearer never moves; the building
/// does.
struct ImmersiveModelView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(ModelStore.self) private var store

    /// Holds the model, and the one entity locomotion writes to.
    @State private var worldRoot = Entity()
    /// The backdrop, deliberately *not* under `worldRoot` — it is the sky, so it must not slide
    /// past when someone travels.
    @State private var skyRoot = Entity()
    @State private var vignette = ComfortVignette()
    @State private var controlsAnchor = Entity()

    @State private var locomotion = LocomotionController()
    @State private var thermal = ThermalQuality()
    @State private var devicePose = DevicePose()
    @State private var notices = ImmersiveNotices()

    @State private var arkitSession = ARKitSession()
    @State private var worldTracking = WorldTrackingProvider()
    @State private var poseSubscription: EventSubscription?

    /// What a change of quality setup actually depends on.
    private struct QualityKey: Equatable {
        let url: URL?
        let constrained: Bool
    }

    /// How far in front of and below the wearer's gaze the controls sit, in meters.
    private static let controlsDistance: Float = 0.62
    private static let controlsDrop: Float = 0.34
    /// Time constant of the controls' follow, in seconds. Long enough that the panel doesn't chase
    /// every glance, short enough that it is back within reach a moment after someone turns.
    private static let controlsLagTime: Float = 0.45

    var body: some View {
        RealityView { content in
            content.add(skyRoot)
            content.add(worldRoot)
            content.add(controlsAnchor)

            skyRoot.addChild(PreviewEnvironment.makeBackdrop(
                radius: PreviewEnvironment.immersiveBackdropRadius
            ))

            do {
                PreviewEnvironment.applyLighting(
                    try await PreviewEnvironment.makeEnvironment(),
                    to: worldRoot
                )
            } catch {
                notices[.lighting] = """
                The preview environment is unavailable, so this model is rendering unlit. \
                \(error.userFacingDescription)
                """
            }

            if let overlay = vignette.makeEntity() {
                content.add(overlay)
            }

            // The attachment is hosted once. Everything it displays comes from `@Observable`
            // holders — the store, the locomotion controller, the thermal monitor, and the notices
            // — so it re-renders on its own; nothing here has to rebuild it. Its environment is
            // injected explicitly rather than inherited, because a view hosted through
            // `ViewAttachmentComponent` is not inside this view's environment.
            controlsAnchor.components.set(ViewAttachmentComponent(rootView: ImmersiveControlsPanel(
                locomotion: locomotion,
                thermal: thermal,
                notices: notices
            )
            .environment(appModel)
            .environment(store)))

            // `make` runs once, so this subscribes exactly once. The holders are captured directly
            // rather than through `self` so the closure doesn't depend on a view struct that
            // SwiftUI re-creates on every invalidation.
            let tracking = worldTracking
            let pose = devicePose
            let vignetteHolder = vignette
            let locomotionHolder = locomotion
            let anchor = controlsAnchor

            locomotion.attach(to: content) { pose.viewerFrame }

            poseSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                // One anchor query per frame, shared by everything that needs the head pose.
                pose.refresh(from: tracking)
                vignetteHolder.update(
                    devicePose: pose.transform,
                    intensity: locomotionHolder.vignetteIntensity
                )
                Self.followGaze(anchor, pose: pose, deltaTime: Float(event.deltaTime))
            }
        } update: { _ in
            store.attach(to: worldRoot, as: .immersive, activeMode: appModel.selectedPreviewMode)
            // 1:1 means the model sits at the rig's origin untransformed. The unit correction is
            // already applied inside the model, so there is nothing left for this level to scale.
            if store.owner == .immersive {
                store.root?.transform = Transform()
            }
        }
        .task {
            await startWorldTracking()
            await positionAtEntryPoint()
        }
        // Detail and shadow quality are set up per model and per thermal state, not per update
        // pass: re-adding the components on every invalidation is work for no change.
        .task(id: QualityKey(url: store.loadedURL, constrained: thermal.isConstrained)) {
            LevelOfDetail.apply(
                store.lodGroups,
                for: .immersive,
                thermallyConstrained: thermal.isConstrained
            )
            thermal.applyShadowQuality(to: store.root)
        }
        .onAppear {
            appModel.immersiveSpaceState = .open
        }
        .onDisappear {
            locomotion.setTarget(nil, entryTransform: Transform())
            poseSubscription?.cancel()
            arkitSession.stop()
            store.detach(.immersive)
            appModel.immersiveSpaceDidClose()
        }
    }

    // MARK: - Entry

    @MainActor
    private func startWorldTracking() async {
        // A platform without world tracking is a capability, not a failure, and there is nothing
        // the person could do about it — so it stays silent.
        guard WorldTrackingProvider.isSupported, worldTracking.state != .running else { return }
        do {
            try await arkitSession.run([worldTracking])
            notices[.tracking] = nil
        } catch {
            // Not fatal: `viewerFrame` falls back to visionOS's conventional initial immersive
            // frame, so the model still appears and travel still moves it. What's lost is the
            // heading, which is what lets someone steer by turning their head — so a silent
            // fallback would read as broken controls.
            notices[.tracking] = """
            Head tracking didn't start, so the model is positioned from a default viewpoint and \
            travel can't be steered by turning your head. \(error.userFacingDescription)
            """
        }
    }

    /// Puts the model's entry point at the wearer's feet and hands the rig to locomotion.
    @MainActor
    private func positionAtEntryPoint() async {
        let deviceTransform = await currentDeviceTransform()
        devicePose.adopt(deviceTransform)
        let entry = ModelPlacement.immersiveEntryTransform(
            entryPoint: store.entryPoint,
            relativeTo: deviceTransform
        )
        worldRoot.transform = entry
        locomotion.setTarget(worldRoot, entryTransform: entry)
    }

    /// Device-anchor queries don't require world-sensing authorization. Waiting briefly gives the
    /// provider time to produce its first tracked pose immediately after the space opens.
    @MainActor
    private func currentDeviceTransform() async -> Transform? {
        for _ in 0..<20 {
            if let transform = devicePose.query(from: worldTracking) {
                return transform
            }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return nil }
        }
        return nil
    }

    // MARK: - Controls follow

    /// Moves the controls towards a point in front of and below the wearer's gaze, with a soft lag.
    ///
    /// Yaw only, and no pitch in the target position: controls that tilted with the head would
    /// swing out of reach whenever someone looked up at a ceiling, which is a thing people do
    /// constantly inside a building.
    private static func followGaze(_ anchor: Entity, pose: DevicePose, deltaTime: Float) {
        let frame = pose.viewerFrame
        let target = frame.position
            + frame.forward * controlsDistance
            + SIMD3<Float>(0, -controlsDrop, 0)

        let blend = min(1, max(deltaTime, 0) / controlsLagTime)
        anchor.position += (target - anchor.position) * blend

        // Face the wearer, level. The panel's own +Z is its front, so the rotation takes +Z to the
        // direction back towards the head.
        let toViewer = frame.position - anchor.position
        let horizontal = SIMD3<Float>(toViewer.x, 0, toViewer.z)
        guard simd_length(horizontal) > 0.01 else { return }
        anchor.orientation = simd_quatf(
            from: SIMD3<Float>(0, 0, 1),
            to: simd_normalize(horizontal)
        )
    }
}

/// The immersive attachment: locomotion, the mode picker, and anything the app needs to say about
/// the state it is in.
///
/// A separate view rather than a computed property on `ImmersiveModelView`, because it is hosted
/// once by `ViewAttachmentComponent` — a captured `@ViewBuilder` property would freeze the view
/// struct it was built from, and its notices would never update again.
private struct ImmersiveControlsPanel: View {
    let locomotion: LocomotionController
    let thermal: ThermalQuality
    let notices: ImmersiveNotices

    @Environment(AppModel.self) private var appModel
    @Environment(ModelStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            ForEach(ImmersiveNotices.Notice.allCases) { notice in
                if let message = notices[notice] {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .glassBackgroundEffect()
                }
            }

            LocomotionControls(
                locomotion: locomotion,
                altitudeRange: altitudeRange,
                thermalNotice: thermal.notice
            )

            PreviewModePicker(
                fileURL: appModel.previewModelURL,
                modelName: appModel.previewModelName ?? "Model"
            )
        }
    }

    /// How far up and down the altitude slider reaches, from the model's own height.
    ///
    /// Up to a little above the roof, and a little below the ground floor so a basement is
    /// reachable. Derived rather than fixed, because the same control has to serve a bungalow and a
    /// thirty-storey tower.
    private var altitudeRange: ClosedRange<Float> {
        let height = store.bounds.extents.y
        guard height > 0.5 else { return -2...4 }
        return -(height * 0.3)...(height + 3)
    }
}

/// One slot per degradation, so re-entering replaces a message rather than appending another copy
/// of it. Observable so the hosted attachment re-renders when one arrives.
@MainActor
@Observable
final class ImmersiveNotices {
    enum Notice: String, CaseIterable, Identifiable, Sendable {
        case lighting
        case tracking

        var id: Self { self }
    }

    private var messages: [Notice: String] = [:]

    subscript(notice: Notice) -> String? {
        get { messages[notice] }
        set { messages[notice] = newValue }
    }
}

/// The wearer's head pose, read once per frame and shared by everything that needs it.
///
/// A holder rather than a value so the per-frame closure, the locomotion controller, and the
/// vignette all see the same query result — three independent `queryDeviceAnchor` calls per frame
/// would be three answers to the same question.
@MainActor
final class DevicePose {
    private(set) var transform: Transform?

    var viewerFrame: ModelPlacement.ViewerFrame {
        ModelPlacement.viewerFrame(from: transform)
    }

    func refresh(from provider: WorldTrackingProvider) {
        if let queried = query(from: provider) {
            transform = queried
        }
        // A dropped frame of tracking keeps the last good pose rather than snapping the controls
        // and the vignette back to the origin.
    }

    func query(from provider: WorldTrackingProvider) -> Transform? {
        provider
            .queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
            .flatMap { $0.isTracked ? Transform(matrix: $0.originFromAnchorTransform) : nil }
    }

    /// Seeds the pose from the initial entry query, which runs before the per-frame refresh starts.
    func adopt(_ transform: Transform?) {
        guard let transform else { return }
        self.transform = transform
    }
}
