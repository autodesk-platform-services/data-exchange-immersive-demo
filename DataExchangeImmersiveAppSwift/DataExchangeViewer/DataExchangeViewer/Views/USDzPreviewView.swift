//
//  USDzPreviewView.swift
//  DataExchangeViewer
//

import SwiftUI
import RealityKit

/// Portal mode: the model seen through a portal in the app's own plain window, plus the mode picker
/// that leads to the other two.
///
/// This is the default and the cheapest of the three — no passthrough replaced, no volume claimed,
/// nothing to dismiss. It is also deliberately read-only: no gestures, no tools, one tap to promote
/// the model into Volume mode where those live.
struct USDzPreviewView: View {
    let fileURL: URL?
    /// The exchange's display name, threaded down so the loaded RealityKit entity has a meaningful
    /// VoiceOver label.
    let modelName: String
    /// Why there is no model to show yet. `fileURL` alone can't distinguish "still checking" from
    /// "nothing converted yet" from "the conversion failed", and those need different messages —
    /// see `unavailableContent`.
    let conversionState: ConversionState

    @Environment(AppModel.self) private var appModel
    @Environment(ModelStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @State private var portalScene = PortalScene()
    /// A degradation rather than a failure: the model is on screen, but without an environment it
    /// renders as a silhouette against the portal's near-black backdrop. Reported instead of
    /// leaving someone to conclude the geometry or its materials are broken.
    @State private var lightingWarning: String?

    var body: some View {
        Group {
            if fileURL == nil {
                unavailableContent
            } else {
                ZStack(alignment: .bottom) {
                    if appModel.isPortalVisible {
                        portal
                        notices
                    } else if appModel.isTransitioning {
                        // Dismissing and opening windows or immersive spaces are separate
                        // windowing surfaces with their own lifecycles, so a true cross-fade isn't
                        // possible — this is an honest "something's happening" state for the gap.
                        ProgressView("Switching view…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Explicitly sized so its centered content doesn't get pulled down to the
                        // ZStack's `.bottom` alignment, where it would overlap the controls below.
                        ContentUnavailableView(
                            appModel.selectedPreviewMode.title,
                            systemImage: appModel.selectedPreviewMode.symbol,
                            description: Text(appModel.selectedPreviewMode.hint)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        // Attached to the outer Group so Portal remains available while another scene is open, and
        // Volume/Immersive remain visible (but disabled) before a conversion exists.
        .ornament(attachmentAnchor: .scene(.bottom)) {
            PreviewModePicker(fileURL: fileURL, modelName: modelName)
                .padding()
        }
        .task(id: fileURL) {
            guard let fileURL else {
                store.unload()
                appModel.clearPreviewModel()
                return
            }
            appModel.setPreviewModel(url: fileURL, name: modelName)
            await store.load(url: fileURL, name: modelName)
        }
        .onDisappear {
            store.detach(.portal)
        }
    }

    private var portal: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                content.add(await portalScene.makeRoot())
                lightingWarning = portalScene.lightingFailure.map {
                    "The preview environment is unavailable, so this model is rendering unlit. \($0.userFacingDescription)"
                }
            } update: { content in
                let size = content.convert(geometry.size, from: .local, to: .scene)
                portalScene.resizePortal(
                    width: size.x * (1 - 2 * ModelPlacement.portalMarginFraction),
                    height: size.y * (1 - 2 * ModelPlacement.portalMarginFraction)
                )

                guard let container = portalScene.modelContainer else { return }
                store.attach(to: container, as: .portal, activeMode: appModel.selectedPreviewMode)
                if let root = store.root, store.owner == .portal,
                   let fit = ModelPlacement.portalFitTransform(bounds: store.bounds) {
                    root.transform = fit
                }
            }
            .gesture(portalTap)
        }
        // Depth is set once, on the reader, which proposes it to the RealityView inside.
        .frame(depth: Double(ModelPlacement.portalDepth))
    }

    /// The portal's only interaction. A tap is a deliberately small commitment — it opens the
    /// volume, where manipulation and the tools live, rather than trying to make a portal in a flat
    /// window behave like one.
    private var portalTap: some Gesture {
        TapGesture()
            .targetedToAnyEntity()
            .onEnded { _ in
                guard let fileURL, store.root != nil else { return }
                appModel.setPreviewModel(url: fileURL, name: modelName)
                appModel.selectedPreviewMode = .volume
                openWindow(id: appModel.volumeWindowID)
            }
    }

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 8) {
            if let message = store.loadError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else {
                ForEach(Array(store.warnings)) { warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lightingWarning {
                    Label(lightingWarning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .opacity(store.loadError == nil && store.warnings.isEmpty && lightingWarning == nil ? 0 : 1)
    }

    /// Shown in place of the preview whenever there is no USDZ to display. The transient states
    /// (checking, converting, downloading) say what they are waiting on and how far along it is,
    /// because they resolve on their own; the terminal ones get a `ContentUnavailableView` because
    /// they need the person to do something.
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

        // `.completed` without a file URL isn't reachable today (the store publishes the URL before
        // the state), but it falls back to the actionable message rather than a spinner.
        case .notConverted, .completed:
            ContentUnavailableView("Run a conversion to preview", systemImage: "cube")
        }
    }

    /// The service reports no percentage for the conversion itself, so a determinate bar would have
    /// to invent one. Elapsed time is the honest substitute: it shows the wait is still moving, and
    /// `Text(_:style:)` keeps itself up to date without a timer to start or stop.
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

    /// The download does have a real byte count, and for a multi-hundred-megabyte BIM export it is
    /// the part of the wait worth measuring. Falls back to an indeterminate bar when the service
    /// answers without a Content-Length, since the fraction is unknowable then.
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
}

extension ModelStore.Warning {
    /// What a degraded model means for the person, rather than what it means to the loader.
    var message: String {
        switch self {
        case .flattenedHierarchy:
            String(localized: "This export has no named sub-assemblies, so Section and Explode have nothing to separate. Re-export with its hierarchy preserved to use them.")
        case .unknownUnits:
            String(localized: "This export doesn't declare its units, so its size in Immersive is a guess.")
        }
    }
}
