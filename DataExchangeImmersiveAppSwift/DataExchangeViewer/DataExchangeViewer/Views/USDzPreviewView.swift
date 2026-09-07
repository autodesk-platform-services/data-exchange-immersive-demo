//
//  USDzPreviewView.swift
//  DataExchangeViewer
//

import SwiftUI
import RealityKit

struct USDzPreviewView: View {
    let fileURL: URL?
    /// The exchange's display name, threaded down to the immersive preview so the loaded
    /// RealityKit entity has a meaningful VoiceOver label.
    let modelName: String
    /// Why there is no model to show yet. `fileURL` alone can't distinguish "still checking"
    /// from "nothing converted yet" from "the conversion failed", and those need different
    /// messages — see `unavailableContent`.
    let conversionState: ConversionState
    @Environment(AppModel.self) private var appModel
    @State private var portalScene = PortalScene()
    @State private var loadError: String?
    /// A degradation rather than a failure: the model is on screen, but without the studio
    /// environment it renders effectively unlit. Reported instead of leaving someone to conclude
    /// the geometry or its materials are broken.
    @State private var lightingWarning: String?

    /// Fraction of each dimension kept as a gap on *each side* between the portal opening and
    /// the edges of the space it occupies, so it reads as a framed opening rather than content
    /// that bleeds to the edges. Proportional (rather than a fixed size) so it scales with the
    /// space instead of swallowing whichever dimension happens to be smaller.
    private static let portalMarginFraction: Float = 0.025

    /// Depth of the volume the portal looks into. `fitBehindPortal` sizes and positions the model
    /// against this same value, so the geometry can't end up outside the declared frame.
    private static let portalDepth: Float = 0.4

    var body: some View {
        Group {
            if fileURL == nil {
                unavailableContent
            } else {
                ZStack(alignment: .bottom) {
                    if appModel.isPeekVisible {
                        GeometryReader3D { geometry in
                            RealityView { content in
                                content.add(await portalScene.makeRoot())
                                lightingWarning = portalScene.lightingFailure.map {
                                    "Studio lighting is unavailable, so this model is rendering unlit. \($0.userFacingDescription)"
                                }
                            } update: { content in
                                // The model is attached from the load task rather than here, so
                                // this closure only has to keep the portal opening sized — and
                                // `PortalScene` skips the mesh work when the size is unchanged.
                                let size = content.convert(geometry.size, from: .local, to: .scene)
                                portalScene.resizePortal(
                                    width: size.x * (1 - 2 * Self.portalMarginFraction),
                                    height: size.y * (1 - 2 * Self.portalMarginFraction)
                                )
                            }
                        }
                        // Depth is set once, on the reader, which proposes it to the RealityView
                        // inside. It used to be applied on both.
                        .frame(depth: Double(Self.portalDepth))

                        if let loadError {
                            Text(loadError)
                                .foregroundStyle(.red)
                                .padding()
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        } else if let lightingWarning {
                            Text(lightingWarning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding()
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else if appModel.isTransitioning {
                        // Dismissing/opening a window or immersive space are separate windowing
                        // surfaces with their own lifecycles, so a true cross-fade isn't possible —
                        // this is an honest "something's happening" state for the gap between them.
                        ProgressView("Switching view…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Explicitly sized so its centered content doesn't get pulled down to the
                        // ZStack's `.bottom` alignment, where it would overlap the controls below.
                        ContentUnavailableView(
                            appModel.selectedPreviewMode == .enter ? "Inside the model" : "Placed in your space",
                            systemImage: appModel.selectedPreviewMode == .enter ? "figure.walk" : "move.3d"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        // Attached to the outer Group so Peek remains available while the spatial scene is open,
        // and Place/Enter remain visible (but disabled) before a conversion exists.
        .ornament(attachmentAnchor: .scene(.bottom)) {
            PreviewModePicker(fileURL: fileURL, modelName: modelName)
                .padding()
        }
        .task(id: PeekModelKey(fileURL: fileURL, isPeekVisible: appModel.isPeekVisible)) {
            portalScene.setModel(nil)
            loadError = nil
            // Peek gives up its copy of the model while Place or Enter owns the presentation, so
            // a BIM-scale entity isn't resident in two scenes at once. Coming back to Peek is
            // still cheap: `USDzEntityCache` clones the already-parsed file.
            guard appModel.isPeekVisible, let fileURL else { return }
            do {
                let entity = try await USDzEntityCache.shared.entity(at: fileURL)
                Self.fitBehindPortal(entity)
                portalScene.setModel(entity)
            } catch {
                loadError = "Failed to load preview: \(error.localizedDescription)"
            }
        }
    }

    /// Reloading is driven by the pair, not just the file: the model is released when Peek stops
    /// being the visible mode and re-attached when it becomes visible again.
    private struct PeekModelKey: Equatable {
        let fileURL: URL?
        let isPeekVisible: Bool
    }

    /// Shown in place of the preview whenever there is no USDZ to display. The transient states
    /// (checking, converting, downloading) say what they are waiting on and how far along it is,
    /// because they resolve on their own; the terminal ones get a `ContentUnavailableView`
    /// because they need the person to do something.
    @ViewBuilder
    private var unavailableContent: some View {
        switch conversionState {
        case .checking:
            ProgressView("Checking the exchange status")

        case .running(let activity):
            switch activity.phase {
            case .converting:
                convertingContent(activity)
            case .downloading(let received, let total):
                downloadingContent(activity, received: received, total: total)
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Conversion failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }

        // `.completed` without a file URL isn't reachable today (the store publishes the URL
        // before the state), but it falls back to the actionable message rather than a spinner.
        case .notConverted, .completed:
            ContentUnavailableView("Run a conversion to preview", systemImage: "cube")
        }
    }

    /// The service reports no percentage for the conversion itself, so a determinate bar would
    /// have to invent one. Elapsed time is the honest substitute: it shows the wait is still
    /// moving, and `Text(_:style:)` keeps itself up to date without a timer to start or stop.
    private func convertingContent(_ activity: ConversionActivity) -> some View {
        VStack(spacing: 8) {
            ProgressView("Converting to USDZ")
            Text(activity.since, style: .timer)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Time spent waiting")
            Text("Large exchanges can take a few minutes. The conversion log is available from the toolbar menu, and the toolbar's Cancel button stops it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    /// The download does have a real byte count, and for a multi-hundred-megabyte BIM export it
    /// is the part of the wait worth measuring. Falls back to an indeterminate bar when the
    /// service answers without a Content-Length, since the fraction is unknowable then.
    @ViewBuilder
    private func downloadingContent(
        _ activity: ConversionActivity,
        received: Int64,
        total: Int64?
    ) -> some View {
        let receivedLabel = received.formatted(.byteCount(style: .file))
        VStack(spacing: 8) {
            if let fraction = activity.fractionCompleted, let total {
                ProgressView(value: fraction) {
                    Text("Downloading the converted model")
                } currentValueLabel: {
                    Text("\(receivedLabel) of \(total.formatted(.byteCount(style: .file)))")
                }
            } else {
                ProgressView("Downloading the converted model")
                Text(receivedLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 360)
        .padding()
    }

    /// USDZ files bake in their own arbitrary position/scale, which otherwise lands the model right
    /// at (or in front of) the portal opening instead of receding behind it. This centers and scales
    /// the loaded entity so it reads as embedded inside the portal rather than popping out in front
    /// of the window.
    ///
    /// Both faces have to stay inside the volume, which runs from the window plane at z = 0 back to
    /// z = -`portalDepth`. Centering the model at half that depth and capping its largest dimension
    /// at the depth less a clearance per side keeps the near face behind the opening and the far
    /// face off the back wall whatever the model's proportions. A fixed 0.35 m size at z = -0.3 put
    /// the far face of a cube-ish model at roughly z = -0.475 — outside a 0.4 m volume.
    private static func fitBehindPortal(_ entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let maxDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard maxDimension > 0 else { return }

        let clearance: Float = 0.05
        let scale = (portalDepth - 2 * clearance) / maxDimension
        entity.scale = SIMD3<Float>(repeating: scale)

        let scaledCenter = bounds.center * scale
        let centerDepth = -portalDepth / 2
        entity.position = SIMD3<Float>(
            -scaledCenter.x,
            -scaledCenter.y,
            -scaledCenter.z + centerDepth
        )
    }
}
