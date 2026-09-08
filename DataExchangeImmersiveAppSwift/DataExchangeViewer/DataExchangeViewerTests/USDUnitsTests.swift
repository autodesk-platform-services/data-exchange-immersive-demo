//
//  USDUnitsTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
import RealityKit
import USDKit
@testable import DataExchangeViewer

/// Pins the two loader behaviours the whole unit story rests on, and the reconciliation built on
/// top of them.
///
/// These are the tests that stop someone "fixing" `USDUnitScale` by multiplying by `metersPerUnit`,
/// which is the obvious reading of the requirement and is destructively wrong: RealityKit has
/// already applied it. Written against a USDA generated at run time rather than a checked-in
/// fixture, so the assertion is about the SDK's behaviour and not about a file someone might
/// re-export.
@MainActor
@Suite("USD units")
struct USDUnitsTests {
    private func write(_ usda: String) throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("units-\(UUID().uuidString).usda")
        try usda.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func millimetreCube() -> String {
        """
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 0.001
            upAxis = "Y"
        )

        def Xform "Root"
        {
            def Cube "Box"
            {
                double size = 1000
            }
        }
        """
    }

    /// The load-bearing fact: a 1000-unit cube on a millimetre stage comes back measuring one
    /// metre, with the conversion baked into the root's scale. If this ever changes,
    /// `USDUnitScale.residual` is what has to change with it.
    @Test func realityKitAppliesMetersPerUnitOnLoad() async throws {
        let url = try write(millimetreCube())
        defer { try? FileManager.default.removeItem(at: url) }

        let entity = try await Entity(contentsOf: url)
        let extents = entity.visualBounds(relativeTo: nil).extents

        #expect(abs(extents.x - 1) < 1e-3, "a 1000 mm cube should measure 1 m")
        #expect(abs(entity.scale.x - 0.001) < 1e-6, "the conversion should be on the loaded root")
    }

    /// The second load-bearing fact: a Z-up stage is levelled on load, which is why the immersive
    /// entry transform can use an identity rotation and still be gravity-aligned.
    @Test func realityKitLevelsAZUpStageOnLoad() async throws {
        let url = try write("""
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Root"
        {
            def Cube "Box"
            {
                double size = 2
            }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let entity = try await Entity(contentsOf: url)
        // The stage's up axis (+Z) should have been rotated onto the scene's (+Y).
        let modelUp = entity.orientation.act(SIMD3<Float>(0, 0, 1))
        #expect(modelUp ≈ SIMD3<Float>(0, 1, 0))
    }

    /// Authored prim names survive the load, which is what makes the `entryPoint` convention and
    /// the flattened-hierarchy check possible at all.
    @Test func authoredPrimNamesSurviveTheLoad() async throws {
        let url = try write("""
        #usda 1.0
        (
            defaultPrim = "Building"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Building"
        {
            def Xform "Level_01"
            {
                def Xform "entryPoint"
                {
                    double3 xformOp:translate = (5, 0, 0)
                    uniform token[] xformOpOrder = ["xformOp:translate"]
                }
            }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let entity = try await Entity(contentsOf: url)
        let entry = try #require(entity.findEntity(named: "entryPoint"))
        #expect(entry.position(relativeTo: nil) ≈ SIMD3<Float>(5, 0, 0))
    }

    @Test func readsTheStagesUnitsAndUpAxis() throws {
        let url = try write(millimetreCube())
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try USDStageMetadata.read(from: url)
        #expect(metadata.metersPerUnit == 0.001)
        #expect(metadata.hasAuthoredMetersPerUnit)
        #expect(!metadata.isZUp)
    }

    // MARK: - Reconciliation

    /// The normal case, and the one the destructive bug would have broken: the loader already
    /// applied the stage's units, so there is nothing left to correct.
    @Test func residualIsUnityWhenTheLoaderAlreadyAppliedTheUnits() {
        let metadata = USDStageMetadata(
            metersPerUnit: 0.001,
            hasAuthoredMetersPerUnit: true,
            isZUp: false
        )
        #expect(USDUnitScale.residual(for: metadata, appliedRootScale: 0.001) == 1)
    }

    /// The case the residual exists for: the stage says millimetres and the loaded root is
    /// unscaled, so the correction is the full conversion.
    @Test func residualIsTheFullConversionWhenTheLoaderAppliedNone() {
        let metadata = USDStageMetadata(
            metersPerUnit: 0.001,
            hasAuthoredMetersPerUnit: true,
            isZUp: false
        )
        #expect(USDUnitScale.residual(for: metadata, appliedRootScale: 1) == 0.001)
    }

    /// An export that never declared its units gives nothing to reconcile against, and USD's
    /// fallback would break the common case of an exporter writing metres implicitly.
    @Test func residualIsUnityWithoutAnAuthoredDeclaration() {
        let metadata = USDStageMetadata(
            metersPerUnit: 0.01,
            hasAuthoredMetersPerUnit: false,
            isZUp: false
        )
        #expect(USDUnitScale.residual(for: metadata, appliedRootScale: 1) == 1)
    }

    @Test func residualIsUnityWithoutAnyMetadata() {
        #expect(USDUnitScale.residual(for: nil, appliedRootScale: 1) == 1)
    }

    /// A correction of a million is a misread, not a unit system, and applying it is the outcome
    /// this guard exists to avoid.
    @Test func residualRejectsImplausibleCorrections() {
        let metadata = USDStageMetadata(
            metersPerUnit: 1,
            hasAuthoredMetersPerUnit: true,
            isZUp: false
        )
        #expect(USDUnitScale.residual(for: metadata, appliedRootScale: 1e-7) == 1)
    }

    /// A degenerate root scale would otherwise divide by zero and hand back an infinity, which as a
    /// scale makes the model disappear rather than resize.
    @Test func residualSurvivesADegenerateRootScale() {
        let metadata = USDStageMetadata(
            metersPerUnit: 0.001,
            hasAuthoredMetersPerUnit: true,
            isZUp: false
        )
        #expect(USDUnitScale.residual(for: metadata, appliedRootScale: 0) == 1)
        #expect(USDUnitScale.residual(for: metadata, appliedRootScale: .nan) == 1)
    }
}
