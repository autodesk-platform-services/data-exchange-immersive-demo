//
//  LevelOfDetail.swift
//  DataExchangeViewer
//

import Foundation
import RealityKit

/// Wires up `LevelOfDetailComponent` for exports that carry authored detail levels.
///
/// `LevelOfDetailComponent` swaps between representations that already exist in the asset — it does
/// not simplify geometry. So this can only do something for a USDZ whose author (or converter) put
/// multiple versions of each assembly in it, conventionally as sibling groups named `LOD0`, `LOD1`,
/// and so on, with 0 the most detailed.
///
/// **The conversion service does not currently emit those.** Generating LOD representations during
/// conversion is a separate, unimplemented piece of work, so on today's artifacts `groups` comes
/// back empty and `apply` is a no-op. This is the plumbing, placed so that the day the pipeline
/// starts producing levels the app uses them, and so that "LOD is on" is a checkable claim rather
/// than an assumed one.
enum LevelOfDetail {
    /// One entity holding several `LOD<n>` children.
    struct Group {
        let parent: Entity
        /// Detail levels in order, most detailed first.
        let levels: [[Entity]]
    }

    /// Distance in meters at which each successive level takes over, most detailed first. Chosen
    /// for architecture at 1:1: a facade's detail matters within a few metres and not at forty.
    static let cameraDistanceThresholds: [Float] = [8, 25, 80]

    /// Screen-area fractions at which each level takes over, most detailed first. Portal and Volume
    /// show the whole model at a small apparent size, where distance is nearly constant and how
    /// much of the display the model covers is the useful signal instead.
    static let screenAreaThresholds: [Float] = [0.2, 0.05, 0.01]

    /// Multiplier applied to distance thresholds when the device is thermally stressed — lower
    /// means the coarser levels take over sooner.
    static let thermalTightening: Float = 0.5

    /// Finds authored LOD groups anywhere in `root`.
    static func groups(in root: Entity) -> [Group] {
        var found: [Group] = []
        var queue = [root]

        while let entity = queue.popLast() {
            let levels = entity.children
                .compactMap { child -> (Int, Entity)? in
                    guard let index = levelIndex(of: child.name) else { return nil }
                    return (index, child)
                }
                .sorted { $0.0 < $1.0 }

            if levels.count > 1 {
                found.append(Group(parent: entity, levels: levels.map { [$0.1] }))
                // A level's own contents aren't searched further: nested LOD inside an LOD level is
                // not a convention any exporter writes, and descending would find the same meshes
                // again under several parents.
                continue
            }
            queue.append(contentsOf: entity.children)
        }
        return found
    }

    /// `LOD0` → 0, `lod_2` → 2, anything else → nil.
    static func levelIndex(of name: String) -> Int? {
        let lowered = name.lowercased()
        guard lowered.hasPrefix("lod") else { return nil }
        let digits = lowered.dropFirst(3).drop { $0 == "_" || $0 == "-" }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// Applies the strategy each mode wants.
    ///
    /// Camera distance for Immersive, where the person moves through the model and distance is what
    /// changes; screen area for Portal and Volume, where the model is a fixed small object and its
    /// apparent size is what changes as the volume is resized.
    static func apply(
        _ groups: [Group],
        for mode: PreviewMode,
        thermallyConstrained: Bool = false
    ) {
        for group in groups {
            switch mode {
            case .immersive:
                let scale = thermallyConstrained ? thermalTightening : 1
                let levels = zip(group.levels, cameraDistanceThresholds).map {
                    (entities: $0.0, maxDistance: $0.1 * scale)
                }
                guard !levels.isEmpty else { continue }
                LevelOfDetailComponent.addByCameraDistance(to: group.parent, levels: levels)

            case .portal, .volume:
                let scale = thermallyConstrained ? 1 / thermalTightening : 1
                let levels = zip(group.levels, screenAreaThresholds).map {
                    (entities: $0.0, minArea: $0.1 * scale)
                }
                guard !levels.isEmpty else { continue }
                LevelOfDetailComponent.addByScreenArea(to: group.parent, levels: levels)
            }
        }
    }
}
