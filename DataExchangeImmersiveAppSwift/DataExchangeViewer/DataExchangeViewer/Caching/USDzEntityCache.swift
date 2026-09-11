//
//  USDzEntityCache.swift
//  DataExchangeViewer
//

import Foundation
import RealityKit

/// Parses a USDZ file once and hands out clones of the result.
///
/// `ModelStore` loads a model once and re-parents it between scenes, so this covers the remaining
/// case: leaving an exchange and coming back to it, or Quick Look opening the same file. A clone
/// shares the underlying `MeshResource` and materials, so the geometry is read and uploaded once
/// rather than a BIM model being parsed and held twice.
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
