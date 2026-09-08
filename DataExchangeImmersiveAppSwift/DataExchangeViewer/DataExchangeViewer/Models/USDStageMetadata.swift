//
//  USDStageMetadata.swift
//  DataExchangeViewer
//

import Foundation
import USDKit

/// What the app needs to know about a USDZ's *stage* rather than its geometry: the units it was
/// authored in, and which way is up.
///
/// Read with USDKit rather than inferred from the loaded entity, because an architectural export
/// arriving in millimetres and one arriving in metres produce identical-looking RealityKit
/// hierarchies — the difference only shows up at 1:1 in Immersive, by which point the model is
/// either a doll's house or a continent.
struct USDStageMetadata: Sendable, Equatable {
    /// The stage's effective `metersPerUnit`: 0.001 for a millimetre export, 0.01 for centimetres,
    /// 1 for metres. Effective, not authored — USD supplies a fallback when the export omits it.
    let metersPerUnit: Double
    /// Whether the export actually declared its units. When it didn't, nothing here is trustworthy
    /// enough to correct a scale by, so `unitScale` leaves the model alone.
    let hasAuthoredMetersPerUnit: Bool
    /// True for a `Z`-up stage, which is what most AEC tools write. RealityKit rotates these on
    /// load, so this is reported for diagnostics rather than acted on.
    let isZUp: Bool

    /// Reads the stage without pulling in payloads — this opens a file to look at three pieces of
    /// metadata, and loading the geometry to do it would double the cost of every conversion.
    ///
    /// `nonisolated` and synchronous: callers run it off the main actor. `USDStage` isn't Sendable,
    /// so it is created, read, and discarded entirely inside this call.
    nonisolated static func read(from url: URL) throws -> USDStageMetadata {
        let stage = try USDStage.open(url, loadingPayloads: .none)
        return USDStageMetadata(
            metersPerUnit: stage.metersPerUnit,
            hasAuthoredMetersPerUnit: stage.hasAuthoredMetersPerUnit,
            isZUp: stage.upAxis.string.uppercased() == "Z"
        )
    }
}

/// Reconciles the stage's declared units against what RealityKit's loader already did with them.
///
/// The naive reading of "don't assume metres" is to multiply the model by `metersPerUnit`. That is
/// wrong here, and destructively so: RealityKit's USD loader *already* applies the stage's units,
/// baking them into the scale of the entity it hands back — a 1000-unit cube on a millimetre stage
/// comes back measuring exactly 1 m, with `scale == 0.001` on its root. Multiplying again would
/// shrink a millimetre building by a further 1000×, and the mode where that matters most is the one
/// where it is least recoverable. `USDUnitsTests` pins the loader behaviour this depends on.
///
/// So what's stored on `ModelStore` is the *residual*: the correction still needed to reach metres
/// after the loader's own conversion. Normally 1. It stops being 1 only if the loader's units and
/// the stage's disagree, which is the case this exists to survive.
enum USDUnitScale {
    /// Beyond this ratio the disagreement is more likely a misread than a real unit mismatch, and
    /// applying it would be the destructive outcome above. Covers millimetres through kilometres.
    static let plausibleRange: ClosedRange<Float> = 0.0001...1000

    /// - Parameters:
    ///   - metadata: the stage's own declaration, or nil when it couldn't be read.
    ///   - appliedRootScale: the uniform scale RealityKit baked into the loaded root.
    static func residual(for metadata: USDStageMetadata?, appliedRootScale: Float) -> Float {
        // No declaration to reconcile against: whatever the loader chose is the only information
        // there is, and second-guessing it with USD's fallback units would break the common case
        // of an exporter that writes metres without saying so.
        guard let metadata, metadata.hasAuthoredMetersPerUnit else { return 1 }

        let declared = Float(metadata.metersPerUnit)
        guard declared > 0, appliedRootScale.isFinite, abs(appliedRootScale) > 1e-9 else { return 1 }

        // Total scale to metres should be `declared`; the loader contributed `appliedRootScale`.
        let residual = declared / appliedRootScale
        guard plausibleRange.contains(residual) else { return 1 }
        // Anything within a fraction of a percent is the loader having already done the work, and
        // is left at exactly 1 rather than a scale of 0.9999 nothing asked for.
        return abs(residual - 1) < 0.001 ? 1 : residual
    }
}
