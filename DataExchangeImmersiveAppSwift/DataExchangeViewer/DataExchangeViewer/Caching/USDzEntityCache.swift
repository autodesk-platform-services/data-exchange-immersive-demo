//
//  USDzEntityCache.swift
//  DataExchangeViewer
//

import Foundation
import RealityKit

/// Parses a USDZ file once and hands out clones of the result.
///
/// Peek and the immersive scene each need their own entity — an entity has a single parent, and
/// the two RealityKit scenes coexist while a mode switch is in flight — but they were each calling
/// `Entity(contentsOf:)` on the same file, so a BIM model was parsed twice and held twice. A clone
/// shares the underlying `MeshResource` and materials, so the geometry is read and uploaded once.
///
/// One slot, keyed by URL: opening a different exchange releases the previous source entity, which
/// bounds residency without needing reference counting across scenes.
final class USDzEntityCache {
    static let shared = USDzEntityCache()

    private var sourceURL: URL?
    private var source: Entity?
    private var loadingURL: URL?
    private var loading: Task<Entity, Error>?

    private init() {}

    /// A ready-to-use entity for `url`. Always a clone — the cached source is never handed out,
    /// because callers position and scale what they receive.
    func entity(at url: URL) async throws -> Entity {
        if sourceURL == url, let source {
            return source.clone(recursive: true)
        }

        let task: Task<Entity, Error>
        if loadingURL == url, let loading {
            // A concurrent request for the same file joins the load in flight rather than
            // starting a second parse of it.
            task = loading
        } else {
            loading?.cancel()
            let started = Task { try await Entity(contentsOf: url) }
            loadingURL = url
            loading = started
            task = started
        }

        let entity = try await task.value
        // Only install the result if this is still the file being asked for; a request for a
        // different exchange may have superseded it while the parse was running.
        if loadingURL == url {
            sourceURL = url
            source = entity
            loadingURL = nil
            loading = nil
        }
        return entity.clone(recursive: true)
    }
}
