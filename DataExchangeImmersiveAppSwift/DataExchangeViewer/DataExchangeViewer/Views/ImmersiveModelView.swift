//
//  ImmersiveModelView.swift
//  DataExchangeViewer
//

import SwiftUI
import RealityKit

/// Shows the currently selected USDZ model at true scale, standing on the floor, filling the
/// full immersive space so buildings can be walked through.
struct ImmersiveModelView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        ModelContainerRealityView(
            fileURL: appModel.previewModelURL,
            withBackground: true,
            prepare: Self.prepareForImmersiveViewing
        )
        // An ornament (rather than the flat window's button) so the exit control is always
        // reachable, even when the model's own geometry — placed at real-world scale in `.full`
        // immersion — ends up occluding the window it was opened from.
        .ornament(attachmentAnchor: .scene(.bottom)) {
            Button {
                Task { @MainActor in
                    appModel.immersiveSpaceState = .inTransition
                    await dismissImmersiveSpace()
                }
            } label: {
                Label("Exit", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .padding()
        }
    }

    /// Keeps the model close to real-world scale — data exchanges are often buildings meant to be
    /// walked through — but shrinks it if needed so it stays clear of the visible background
    /// sphere's surface instead of poking through it.
    ///
    /// The immersive space's origin coincides with where the user was standing when they opened
    /// it, so centering the model there would drop them at its centroid — potentially inside its
    /// walls, facing culled backfaces with nothing visible. Pushing it back in -z instead places
    /// it in front of them, so they start outside its footprint and can walk into it.
    private static func prepareForImmersiveViewing(_ entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let maxDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard maxDimension > 0 else { return }

        let halfWidth = bounds.extents.x / 2
        let halfDepth = bounds.extents.z / 2
        let height = bounds.extents.y
        let reach = (halfWidth * halfWidth + height * height + halfDepth * halfDepth).squareRoot()
        let safeRadius = StudioLighting.backgroundSphereRadius * 0.8
        let scale = reach > safeRadius ? safeRadius / reach : 1
        entity.scale = SIMD3<Float>(repeating: scale)

        let scaledCenter = bounds.center * scale
        let scaledHalfDepth = halfDepth * scale
        let standoffDistance = max(scaledHalfDepth + 2, 3)
        entity.position = SIMD3<Float>(-scaledCenter.x, -bounds.min.y * scale, -scaledCenter.z - standoffDistance)
    }
}
