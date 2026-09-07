//
//  USDzCache.swift
//  DataExchangeViewer
//

import Foundation
import CryptoKit
import Observation

/// On-disk store for downloaded USDZ artifacts.
///
/// Two things shape the design. `isCached(for:)` is read from list-row bodies, so it answers from
/// an in-memory index instead of performing a `fileExists` probe per row on every scroll tick and
/// keystroke. And because a single BIM exchange can run to hundreds of megabytes, the store keeps
/// its own size budget rather than relying solely on the system purging `.cachesDirectory`.
@Observable
final class USDzCache {
    /// One instance for the whole app: the in-memory index is only useful if every caller shares
    /// it, and it also means the cache directory is created at most once per launch.
    static let shared = USDzCache()

    /// Bytes of cached artifacts kept before the least recently used files are evicted. Sized to
    /// hold a handful of large exchanges rather than an unbounded history.
    static let sizeBudget: Int64 = 4 * 1024 * 1024 * 1024

    private let directory: URL

    /// Sizes of the files believed to be on disk, keyed by hashed file name. Maintained
    /// incrementally so rendering a row never waits on the filesystem.
    private var fileSizes: [String: Int64] = [:]
    private var hasLoadedIndex = false

    /// Total bytes currently cached. Derived rather than stored so it cannot drift out of step
    /// with `fileSizes`; the dictionary holds one entry per downloaded exchange, not per file
    /// in the app.
    var totalSize: Int64 { fileSizes.values.reduce(0, +) }

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // Not created here — `adopt` creates it on the first write, so simply reading the index
        // on a fresh install doesn't touch the filesystem.
        directory = caches.appendingPathComponent("USDzCache", isDirectory: true)
    }

    /// Seeds the in-memory index from disk. Idempotent, and safe to call from any view that is
    /// about to read `isCached(for:)`. A caller that arrives while the first scan is still
    /// running returns immediately with a cold index — which is fine, because the index only
    /// drives presentation and is observable, so rows fill in when the scan lands. Anything that
    /// must be certain uses `confirmCached(for:)`, which asks the filesystem directly.
    func loadIndexIfNeeded() async {
        guard !hasLoadedIndex else { return }
        hasLoadedIndex = true
        fileSizes = await Self.scan(directory)
        await evictIfNeeded()
    }

    /// Whether an artifact for this exchange is cached, answered from memory. Callers that are
    /// about to open the file should use `confirmCached(for:)` instead.
    func isCached(for exchangeUrn: String) -> Bool {
        fileSizes[Self.fileName(for: exchangeUrn)] != nil
    }

    /// The one check that must not trust the index: the system can purge `.cachesDirectory`
    /// behind the app's back, which would otherwise turn into a failed model load. A single
    /// `stat`, performed when an exchange is opened rather than while rendering.
    func confirmCached(for exchangeUrn: String) -> Bool {
        let name = Self.fileName(for: exchangeUrn)
        let fileURL = directory.appendingPathComponent(name)
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            fileSizes[name] = nil
            return false
        }
        fileSizes[name] = Int64(size)
        markUsed(for: exchangeUrn)
        return true
    }

    func url(for exchangeUrn: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: exchangeUrn))
    }

    /// Takes ownership of a file that `ConversionAPI` streamed to a temporary location, so the
    /// artifact is never held in memory in its entirety.
    @discardableResult
    func adopt(_ downloadedFile: URL, for exchangeUrn: String) async throws -> URL {
        let destination = url(for: exchangeUrn)
        let size = try await Self.install(downloadedFile, at: destination, in: directory)
        fileSizes[destination.lastPathComponent] = size
        await evictIfNeeded()
        return destination
    }

    func delete(for exchangeUrn: String) {
        let fileURL = url(for: exchangeUrn)
        // Synchronous, unlike the bulk operations below: a re-download of the same exchange can
        // follow immediately, and it must not race a deletion still queued on another thread.
        try? FileManager.default.removeItem(at: fileURL)
        fileSizes[fileURL.lastPathComponent] = nil
    }

    /// Removes every cached artifact, so the disk the app is holding is recoverable without
    /// deleting the app itself. An exchange open at the time keeps rendering — its entity is
    /// already parsed — and re-opening it finds nothing cached and downloads again.
    func clearAll() async {
        let names = Array(fileSizes.keys)
        fileSizes = [:]
        await Self.remove(names, in: directory)
    }

    /// Records a cache hit so eviction falls on the genuinely least recently used artifact. The
    /// modification date doubles as the LRU stamp, because access dates are not dependable.
    func markUsed(for exchangeUrn: String) {
        let fileURL = url(for: exchangeUrn)
        Task.detached(priority: .utility) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        }
    }

    private func evictIfNeeded() async {
        guard totalSize > Self.sizeBudget else { return }
        for name in await Self.evict(in: directory, downTo: Self.sizeBudget) {
            fileSizes[name] = nil
        }
    }

    /// Not private: `CacheKeyTests` checks the derivation directly, since a collision or an
    /// unstable key would show up as one exchange serving another's geometry.
    static func fileName(for exchangeUrn: String) -> String {
        let digest = SHA256.hash(data: Data(exchangeUrn.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".usdz"
    }

    // MARK: - Filesystem work

    // Pushed off the main actor with `Task.detached`. Enumerating, moving, and unlinking
    // hundred-megabyte packages is not main-thread work, and under approachable concurrency a
    // plain `nonisolated async` function would inherit the caller's isolation and stay on it.

    private nonisolated static func scan(_ directory: URL) async -> [String: Int64] {
        await Task.detached(priority: .utility) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            return contents.reduce(into: [:]) { sizes, fileURL in
                let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                sizes[fileURL.lastPathComponent] = Int64(size ?? 0)
            }
        }.value
    }

    private nonisolated static func install(
        _ source: URL,
        at destination: URL,
        in directory: URL
    ) async throws -> Int64 {
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            do {
                try manager.moveItem(at: source, to: destination)
            } catch {
                // Different volumes (or a temporary file the system has already reclaimed the
                // directory entry for) make a rename impossible; copying still avoids holding
                // the artifact in memory.
                try manager.copyItem(at: source, to: destination)
                try? manager.removeItem(at: source)
            }
            let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return Int64(size ?? 0)
        }.value
    }

    private nonisolated static func remove(_ fileNames: [String], in directory: URL) async {
        await Task.detached(priority: .utility) {
            for name in fileNames {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }.value
    }

    /// Deletes the oldest artifacts until the total fits the budget, and reports what it removed.
    /// The newest file is always kept: an artifact larger than the whole budget would otherwise
    /// be deleted the instant its download finished.
    private nonisolated static func evict(in directory: URL, downTo budget: Int64) async -> [String] {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let contents = (try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )) ?? []

            let entries = contents.compactMap { fileURL -> (url: URL, size: Int64, modified: Date)? in
                guard let values = try? fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                ) else { return nil }
                return (fileURL, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
            }.sorted { $0.modified < $1.modified }

            var total = entries.reduce(0) { $0 + $1.size }
            var evicted: [String] = []
            for entry in entries.dropLast() where total > budget {
                try? manager.removeItem(at: entry.url)
                total -= entry.size
                evicted.append(entry.url.lastPathComponent)
            }
            return evicted
        }.value
    }
}
