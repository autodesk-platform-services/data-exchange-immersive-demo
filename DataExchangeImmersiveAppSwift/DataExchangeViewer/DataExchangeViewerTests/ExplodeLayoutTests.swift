//
//  ExplodeLayoutTests.swift
//  DataExchangeViewerTests
//

import Testing
import RealityKit
import simd
@testable import DataExchangeViewer

@Suite("Explode layout")
struct ExplodeLayoutTests {
    /// A box of the given size centred at `centre`.
    private func part(_ centre: SIMD3<Float>, _ size: SIMD3<Float>) -> ExplodeLayout.Part {
        ExplodeLayout.Part(bounds: BoundingBox(min: centre - size / 2, max: centre + size / 2))
    }

    /// A four-storey building: wide, shallow slabs stacked up Y.
    private var storeys: [ExplodeLayout.Part] {
        (0..<4).map { part(SIMD3<Float>(0, Float($0) * 3.5 + 1.5, 0), SIMD3<Float>(30, 3, 20)) }
    }

    // MARK: - Axis selection

    @Test func picksTheVerticalAxisForAStackOfStoreys() {
        #expect(ExplodeLayout.axis(for: storeys) ≈ SIMD3<Float>(0, 1, 0))
    }

    /// The regression volume weighting exists to prevent: a storey stack with a lot of small
    /// fixtures spread across each floor plate. Unweighted, the fixtures outvote the storeys by
    /// sheer count and the building explodes sideways.
    @Test func volumeWeightingKeepsFixturesFromOutvotingStoreys() {
        var parts = storeys
        for index in 0..<200 {
            let x = Float(index % 20) * 1.5 - 15
            let z = Float(index / 20) * 2 - 10
            parts.append(part(SIMD3<Float>(x, 1, z), SIMD3<Float>(0.2, 0.2, 0.2)))
        }
        #expect(ExplodeLayout.axis(for: parts) ≈ SIMD3<Float>(0, 1, 0))
    }

    /// A site plan genuinely does spread horizontally, and should explode that way.
    @Test func picksTheHorizontalAxisForABuildingsSpreadAcrossASite() {
        let buildings = (0..<5).map {
            part(SIMD3<Float>(Float($0) * 60, 6, 0), SIMD3<Float>(30, 12, 30))
        }
        #expect(ExplodeLayout.axis(for: buildings) ≈ SIMD3<Float>(1, 0, 0))
    }

    /// Y is the right default for the storey stack this tool is mostly used on, and the only
    /// answer available when there is nothing to measure.
    @Test func fallsBackToVerticalWithNothingToMeasure() {
        #expect(ExplodeLayout.axis(for: []) ≈ SIMD3<Float>(0, 1, 0))
        #expect(ExplodeLayout.axis(for: [part(.zero, SIMD3<Float>(1, 1, 1))]) ≈ SIMD3<Float>(0, 1, 0))
    }

    /// Zero-extent parts — empty groups, locators — weigh nothing, so a model made only of them
    /// has no measurable distribution at all.
    @Test func fallsBackToVerticalWhenEveryPartHasNoVolume() {
        let locators = (0..<4).map { part(SIMD3<Float>(Float($0) * 5, 0, 0), .zero) }
        #expect(ExplodeLayout.axis(for: locators) ≈ SIMD3<Float>(0, 1, 0))
    }

    // MARK: - Offsets

    /// The point of the tool: after a full explode, no two parts overlap along the axis.
    @Test func separatesEveryPartAlongTheAxis() {
        let axis = SIMD3<Float>(0, 1, 0)
        let offsets = ExplodeLayout.offsets(for: storeys, along: axis)

        let intervals = zip(storeys, offsets)
            .map { part, offset -> (low: Float, high: Float) in
                let centre = simd_dot(part.bounds.center + offset, axis)
                let span = abs(simd_dot(part.bounds.extents, axis))
                return (centre - span / 2, centre + span / 2)
            }
            .sorted { $0.low < $1.low }

        for (earlier, later) in zip(intervals, intervals.dropFirst()) {
            #expect(later.low > earlier.high, "parts still overlap after exploding")
        }
    }

    /// Spacing follows each part's own extent, so a thin slab and a thick one both end up clear of
    /// their neighbours — which fixed spacing per index cannot do.
    @Test func spacesUnevenPartsByTheirOwnExtent() {
        let parts = [
            part(SIMD3<Float>(0, 0, 0), SIMD3<Float>(10, 0.2, 10)),
            part(SIMD3<Float>(0, 1, 0), SIMD3<Float>(10, 8, 10)),
            part(SIMD3<Float>(0, 2, 0), SIMD3<Float>(10, 0.2, 10))
        ]
        let axis = SIMD3<Float>(0, 1, 0)
        let offsets = ExplodeLayout.offsets(for: parts, along: axis)

        let intervals = zip(parts, offsets)
            .map { part, offset -> (low: Float, high: Float) in
                let centre = simd_dot(part.bounds.center + offset, axis)
                let span = abs(simd_dot(part.bounds.extents, axis))
                return (centre - span / 2, centre + span / 2)
            }
            .sorted { $0.low < $1.low }

        for (earlier, later) in zip(intervals, intervals.dropFirst()) {
            #expect(later.low > earlier.high)
        }
    }

    /// Exploding shouldn't also translate the whole assembly off to one side of the volume.
    @Test func recentresTheExplodedStack() {
        let offsets = ExplodeLayout.offsets(for: storeys, along: SIMD3<Float>(0, 1, 0))
        let mean = offsets.reduce(SIMD3<Float>.zero, +) / Float(offsets.count)
        #expect(mean ≈ .zero)
    }

    /// Displacement is along the chosen axis only — an offset with any lateral component would
    /// smear the assembly sideways as it comes apart.
    @Test func displacesOnlyAlongTheChosenAxis() {
        let offsets = ExplodeLayout.offsets(for: storeys, along: SIMD3<Float>(0, 1, 0))
        for offset in offsets {
            #expect(abs(offset.x) < 1e-5)
            #expect(abs(offset.z) < 1e-5)
        }
    }

    /// Coincident slabs — a flattened stack with every part at the same height — is exactly the
    /// case someone reaches for explode to untangle, so the gap has to be positive even when the
    /// assembly's own span is zero.
    @Test func separatesCoincidentParts() {
        let coincident = (0..<3).map { _ in part(.zero, SIMD3<Float>(4, 0.2, 4)) }
        let offsets = ExplodeLayout.offsets(for: coincident, along: SIMD3<Float>(0, 1, 0))
        let heights = offsets.map(\.y).sorted()
        for (earlier, later) in zip(heights, heights.dropFirst()) {
            #expect(later > earlier)
        }
    }

    @Test func leavesASinglePartWhereItIs() {
        let offsets = ExplodeLayout.offsets(
            for: [part(.zero, SIMD3<Float>(1, 1, 1))],
            along: SIMD3<Float>(0, 1, 0)
        )
        #expect(offsets == [.zero])
    }

    /// A zero axis has no direction to normalize, and normalizing it would divide by zero.
    @Test func declinesADegenerateAxis() {
        let offsets = ExplodeLayout.offsets(for: storeys, along: .zero)
        #expect(offsets.allSatisfy { $0 == .zero })
    }
}
