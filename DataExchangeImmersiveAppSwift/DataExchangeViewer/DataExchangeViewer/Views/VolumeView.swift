//
//  VolumeView.swift
//  DataExchangeViewer
//

import SwiftUI
import RealityKit
import simd

/// Volume mode: the model in a volumetric window the person places and resizes, with the section
/// and explode tools.
///
/// The volume's position and size belong to them, not to the app — there is no API to move a
/// volumetric window and it would be the wrong thing to do anyway. What the app owns is the fit:
/// the model is re-centred and re-scaled to whatever bounds the volume currently has, on load and
/// on every resize.
struct VolumeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(ModelStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var anchor = Entity()
    @State private var section = SectionBoxTool()
    @State private var explode = ExplodeTool()
    @State private var activeTool: ActiveTool = .none
    @State private var thermal = ThermalQuality()

    /// Which entity the current drag started on, so a drag that began on a section handle keeps
    /// going to the section tool even if the hand wanders off the handle mid-gesture.
    @State private var dragTarget: DragTarget?

    @AppStorage(PreviewModeDefaults.manipulationHintKey) private var hasSeenManipulationHint = false
    @State private var showManipulationHint = false

    /// What a change of level-of-detail setup actually depends on.
    private struct LODKey: Equatable {
        let url: URL?
        let constrained: Bool
    }

    private enum DragTarget: Equatable {
        case sectionFace(SectionBoxGeometry.Face)
        case explode
    }

    var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                // The container the model is parented into. The volume has no environment of its
                // own — a volumetric window keeps passthrough, so the room's own lighting is the
                // right lighting — and the model and its tool overlay belong to the store.
                content.add(volumeAnchor())
            } update: { content in
                guard let root = store.root else { return }
                store.attach(to: volumeAnchor(), as: .volume, activeMode: appModel.selectedPreviewMode)

                // Re-fitted on every bounds change, which is the only way the volume's size
                // changes: the person resizing it.
                let extents = content.convert(geometry.size, from: .local, to: .scene)
                if let fit = ModelPlacement.volumeFitTransform(bounds: store.bounds, volumeExtents: extents) {
                    root.transform = fit
                }
                applyManipulation(to: root)
            }
            .gesture(toolDrag, isEnabled: activeTool != .none)
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            toolbar
        }
        .task(id: store.loadedURL) {
            bindTools()
        }
        // Level of detail is set up per model and per thermal state, not per update pass:
        // re-adding the component on every invalidation is work for no change.
        .task(id: LODKey(url: store.loadedURL, constrained: thermal.isConstrained)) {
            LevelOfDetail.apply(
                store.lodGroups,
                for: .volume,
                thermallyConstrained: thermal.isConstrained
            )
        }
        .task(id: activeTool) {
            guard activeTool == .none, !hasSeenManipulationHint, store.root != nil else { return }
            withAnimation { showManipulationHint = true }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showManipulationHint = false }
            // `try?` swallows cancellation, so activating a tool inside the four-second window used
            // to fall straight through to here and retire the hint after it had been on screen for
            // a fraction of a second. Only a full showing counts as having seen it.
            guard !Task.isCancelled else { return }
            hasSeenManipulationHint = true
        }
        .onAppear {
            appModel.isVolumeOpen = true
        }
        .onDisappear {
            // Order matters: the tools put the model's parts back before it goes anywhere else, so
            // Portal and Immersive never inherit a half-exploded or clipped model.
            explode.deactivate()
            section.deactivate()
            activeTool = .none
            store.detach(.volume)
            appModel.volumeDidClose()
        }
    }

    /// The volume's own content root. `RealityViewContent` isn't an entity, so the model needs a
    /// container inside it to be parented to. Held in `@State` so the update pass doesn't have to
    /// find it again by name on every invalidation.
    private func volumeAnchor() -> Entity {
        anchor.name = "volumeAnchor"
        return anchor
    }

    // MARK: - Tools

    private func bindTools() {
        guard let clipRoot = store.clipRoot, let overlay = store.toolOverlay else { return }
        section.bind(
            clipRoot: clipRoot,
            handleRoot: overlay,
            modelBounds: store.bounds,
            key: store.loadedURL
        )
        explode.bind(to: store)
        activeTool = .none
    }

    /// Activating one tool deactivates the other, and both suspend whole-model manipulation.
    ///
    /// Not a nicety: `ManipulationComponent`, the section box, and explode all write entity
    /// transforms, and two of them live at once produces a fight per frame rather than a
    /// compromise.
    private func select(_ tool: ActiveTool) {
        let newTool = activeTool == tool ? .none : tool
        guard newTool != activeTool else { return }

        switch activeTool {
        case .section: section.deactivate()
        case .explode: explode.deactivate()
        case .none: break
        }

        switch newTool {
        case .section:
            section.activate()
            activeTool = .section
        case .explode:
            // A flattened export has one part; activating on it would present a tool that visibly
            // does nothing, so the selection is refused and the warning already on screen stands.
            activeTool = explode.activate() ? .explode : .none
        case .none:
            activeTool = .none
        }
    }

    /// Manipulation is the default state and only the default state.
    private func applyManipulation(to root: Entity) {
        guard activeTool == .none else {
            root.components.remove(ManipulationComponent.self)
            return
        }
        guard root.components[ManipulationComponent.self] == nil else { return }

        ManipulationComponent.configureEntity(root)
        if var manipulation = root.components[ManipulationComponent.self] {
            // Where someone puts the model is where it stays; springing back to a "correct"
            // position discards the only placement that matters.
            manipulation.releaseBehavior = .stay
            root.components.set(manipulation)
        }
    }

    // MARK: - Gestures

    /// One drag gesture for both tools, routed by what it started on.
    ///
    /// Installed only while a tool is active, so in the default state the system's own manipulation
    /// gestures own every pinch — a custom drag alongside them competes for the same input.
    private var toolDrag: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard let clipRoot = store.clipRoot else { return }

                if dragTarget == nil {
                    dragTarget = begin(on: value.entity)
                }

                // The delta arrives in the *gesture's* frame and has to be applied in the model's,
                // so it is converted straight into `clipRoot` — the model's own metric space, which
                // is where both the section bounds and the explode offsets are expressed.
                let displacement = value.convert(value.translation3D, from: .local, to: clipRoot)

                switch dragTarget {
                case .sectionFace:
                    section.updateDrag(displacement: displacement)
                case .explode:
                    explode.updateDrag(displacement: displacement)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                switch dragTarget {
                case .sectionFace: section.endDrag()
                case .explode: explode.endDrag()
                case nil: break
                }
                dragTarget = nil
            }
    }

    private func begin(on entity: Entity) -> DragTarget? {
        if activeTool == .section, let face = section.face(for: entity) {
            section.beginDrag(face: face)
            return .sectionFace(face)
        }
        if activeTool == .explode {
            explode.beginDrag()
            return .explode
        }
        return nil
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 10) {
            if let message = store.loadError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(8)
                    .glassBackgroundEffect()
            } else if showManipulationHint {
                Label(ActiveTool.none.hint, systemImage: "hand.pinch")
                    .padding(8)
                    .glassBackgroundEffect()
                    .transition(.opacity)
            }

            if activeTool == .section {
                sectionControls
            } else if activeTool == .explode {
                explodeControls
            }

            HStack(spacing: 10) {
                ForEach(ActiveTool.selectable) { tool in
                    Button {
                        select(tool)
                    } label: {
                        Label(tool.title, systemImage: tool.symbol)
                    }
                    .buttonStyle(.bordered)
                    .tint(activeTool == tool ? .accentColor : nil)
                    .accessibilityHint(tool.hint)
                    .accessibilityAddTraits(activeTool == tool ? .isSelected : [])
                }
            }
            .padding(8)
            .glassBackgroundEffect()

            PreviewModePicker(
                fileURL: appModel.previewModelURL,
                modelName: appModel.previewModelName ?? "Model"
            )
        }
        .padding()
    }

    private var sectionControls: some View {
        HStack(spacing: 10) {
            Button {
                section.toggleEditing()
            } label: {
                Label(
                    section.state == .editing ? "Hide Handles" : "Show Handles",
                    systemImage: section.state == .editing ? "eye.slash" : "eye"
                )
            }
            .accessibilityHint("Keeps the cut but hides the draggable faces, so you can look at the section")

            Button {
                section.reset()
            } label: {
                Label("Reset Box", systemImage: "arrow.uturn.backward")
            }
            .accessibilityHint("Returns the section box to the model's full extent")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .glassBackgroundEffect()
    }

    private var explodeControls: some View {
        VStack(spacing: 4) {
            Text("Drag the model to separate its parts \(explode.axisName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The drag is the primary control, but it is a mid-air pinch — a slider is the path for
            // VoiceOver, Full Keyboard Access, and anyone who wants a value rather than a gesture.
            Slider(
                value: Binding(get: { explode.factor }, set: { explode.setFactor($0) }),
                in: 0...1
            ) {
                Text("Explode")
            }
            .frame(width: 260)
            .accessibilityValue("\(Int(explode.factor * 100)) percent")
        }
        .padding(8)
        .glassBackgroundEffect()
    }
}
