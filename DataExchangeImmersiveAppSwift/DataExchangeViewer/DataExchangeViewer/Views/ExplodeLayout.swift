//
//  ExplodeLayout.swift
//  DataExchangeViewer
//

import RealityKit
import simd

/// The arithmetic behind the explode tool: which axis to separate along, and where each part goes.
///
/// Pure functions over bounding boxes, kept out of the tool for the same reason `ModelPlacement`
/// is kept out of the views — axis selection on a real building is exactly the kind of thing that
/// looks right in a headset until the one model where it doesn't, and a test can cover the storey
/// stack, the flat site plan, and the single-part edge case in a second.
enum ExplodeLayout {
    /// A part and the box it occupies in its parent's space.
    struct Part: Equatable {
        let bounds: BoundingBox
        /// Volume of `bounds`, the weight used for axis selection. Zero-extent parts (empty
        /// groups, locators) contribute nothing rather than dragging the mean towards themselves.
        var volume: Float {
            let e = bounds.extents
            return max(e.x, 0) * max(e.y, 0) * max(e.z, 0)
        }
    }

    /// Gap between separated parts, as a fraction of the model's own extent along the chosen axis.
    /// Proportional so one constant works for a 40 m building and a 40 cm bracket.
    static let separationFraction: Float = 0.08

    /// Picks the axis with the largest volume-weighted variance in part position.
    ///
    /// Weighting by volume is what makes this reliable on a building: a multi-storey model has its
    /// mass distributed up the Y axis, so Y wins, while the dozens of small fixtures scattered
    /// across each floor plate don't outvote the storeys by sheer count. An unweighted variance
    /// picks whichever axis has the most *parts* spread along it, which on a floor plan is X or Z —
    /// exploding a building sideways.
    ///
    /// Falls back to Y, the right answer for the storey stack this mode is mostly used on, whenever
    /// there is nothing to measure.
    static func axis(for parts: [Part]) -> SIMD3<Float> {
        let up = SIMD3<Float>(0, 1, 0)
        guard parts.count > 1 else { return up }

        let totalWeight = parts.reduce(Float.zero) { $0 + $1.volume }
        guard totalWeight > 0 else { return up }

        var mean = SIMD3<Float>.zero
        for part in parts {
            mean += part.bounds.center * part.volume
        }
        mean /= totalWeight

        var variance = SIMD3<Float>.zero
        for part in parts {
            let delta = part.bounds.center - mean
            variance += delta * delta * part.volume
        }
        variance /= totalWeight

        if variance.y >= variance.x && variance.y >= variance.z {
            return up
        }
        return variance.x >= variance.z ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1)
    }

    /// Where each part ends up at full explode, as an offset from its rest position.
    ///
    /// Parts are ordered along `axis` and laid out end to end, each one's own extent plus a gap
    /// clear of the last — so a five-storey building separates into five visibly distinct slabs
    /// whatever their individual heights, instead of a fixed per-index spacing, which leaves thin
    /// slabs floating in a void and thick ones still intersecting.
    ///
    /// The finished stack is re-centred on the model's rest centre, so exploding doesn't also
    /// translate the whole assembly off to one side of the volume.
    static func offsets(for parts: [Part], along axis: SIMD3<Float>) -> [SIMD3<Float>] {
        guard parts.count > 1, simd_length(axis) > 0 else {
            return Array(repeating: .zero, count: parts.count)
        }
        let unit = simd_normalize(axis)

        // Extent of the whole assembly along the axis, which sets the gap.
        let coordinates = parts.map { simd_dot($0.bounds.center, unit) }
        let spans = parts.map { abs(simd_dot($0.bounds.extents, unit)) }
        guard let lowest = zip(coordinates, spans).map({ $0 - $1 / 2 }).min(),
              let highest = zip(coordinates, spans).map({ $0 + $1 / 2 }).max() else {
            return Array(repeating: .zero, count: parts.count)
        }
        let assemblySpan = highest - lowest
        // A gap has to be positive even when every part sits at the same coordinate — a flattened
        // stack of coincident slabs is precisely the case someone reaches for explode to untangle.
        let gap = max(assemblySpan * separationFraction, 0.001)

        let order = parts.indices.sorted { coordinates[$0] < coordinates[$1] }
        var scalarOffsets = [Float](repeating: 0, count: parts.count)
        var cursor = lowest
        for index in order {
            let target = cursor + spans[index] / 2
            scalarOffsets[index] = target - coordinates[index]
            cursor += spans[index] + gap
        }

        // Re-centre: shift everything back by the mean displacement.
        let mean = scalarOffsets.reduce(Float.zero, +) / Float(scalarOffsets.count)
        return scalarOffsets.map { unit * ($0 - mean) }
    }
}
