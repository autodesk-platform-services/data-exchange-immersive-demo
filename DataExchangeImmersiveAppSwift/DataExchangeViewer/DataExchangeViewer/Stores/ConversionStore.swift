//
//  ConversionStore.swift
//  DataExchangeViewer
//

import Foundation

enum ConversionState {
    case checking
    case notConverted
    case running
    case completed
    case failed(String)
}

@Observable
final class ConversionStore {
    let exchange: Exchange
    private(set) var state: ConversionState = .checking
    private(set) var cachedUSDzURL: URL?
    private(set) var logText: String = ""

    private let api = ConversionAPI()
    private let cache = USDzCache.shared
    private var pollTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?

    /// Raw log bytes received so far. Kept as `Data` rather than appending to `logText` so a
    /// multi-byte character split across a range boundary still decodes correctly, and so the
    /// byte count is an exact offset for the next range request.
    private var logData = Data()
    /// Whether the conversion log is on screen. The log is only polled while it is: previously
    /// polling started unconditionally from `start`, which meant a guaranteed 404 on every
    /// detail-view open for an exchange that had never been converted.
    private var isLogVisible = false

    /// Status polling starts fast, because a small conversion can finish in a few seconds, then
    /// backs off so a long BIM conversion isn't polled 100 times.
    private static let initialPollInterval: Duration = .seconds(2)
    private static let maximumPollInterval: Duration = .seconds(15)

    init(exchange: Exchange) {
        self.exchange = exchange
    }

    /// Cancels both polling loops. Called from the owning view's `onDisappear`, because a
    /// `deinit` cannot do this job: the properties are main-actor isolated (a hard error under
    /// Swift 6 strict concurrency), and the loops used to hold a strong reference to the store
    /// anyway, so `deinit` was never reached while polling was in flight.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        logTask?.cancel()
        logTask = nil
    }

    func start(auth: AuthManager) async {
        await cache.loadIndexIfNeeded()
        // Deliberately the real filesystem check rather than the in-memory index: this is the
        // point where the file is about to be handed to RealityKit.
        if cache.confirmCached(for: exchange.conversionKeyUrn) {
            cachedUSDzURL = cache.url(for: exchange.conversionKeyUrn)
            state = .completed
            return
        }
        do {
            let token = try await auth.validAccessToken()
            if let metadata = try await api.status(urn: exchange.conversionKeyUrn, token: token) {
                switch metadata.status {
                case .completed:
                    await downloadArtifact(metadata: metadata, auth: auth)
                case .running:
                    state = .running
                    startPolling(auth: auth)
                case .failed:
                    state = .failed(metadata.error ?? "Conversion failed")
                }
            } else {
                state = .notConverted
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func convert(auth: AuthManager) async {
        state = .running
        logData = Data()
        logText = ""
        do {
            let token = try await auth.validAccessToken()
            try await api.start(urn: exchange.conversionKeyUrn, token: token)
        } catch ConversionError.conflict {
            // another client already started a conversion; fall through to polling its progress
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        startPolling(auth: auth)
        startLogPollingIfVisible(auth: auth)
    }

    func clear(auth: AuthManager) async {
        do {
            let token = try await auth.validAccessToken()
            try await api.delete(urn: exchange.conversionKeyUrn, token: token)
            cache.delete(for: exchange.conversionKeyUrn)
            cachedUSDzURL = nil
            logData = Data()
            logText = ""
            state = .notConverted
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Called as the conversion log is presented and dismissed. Nothing observes `logText` while
    /// the sheet is closed, and re-assigning it invalidates the sheet's `Text` — which lays out a
    /// large monospaced, unwrapped body — so the fetch is scoped to the sheet's lifetime.
    func setLogVisible(_ isVisible: Bool, auth: AuthManager) {
        isLogVisible = isVisible
        if isVisible {
            startLogPollingIfVisible(auth: auth)
        } else {
            logTask?.cancel()
            logTask = nil
        }
    }

    private func startPolling(auth: AuthManager) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(5 * 60)
            var interval = Self.initialPollInterval
            while !Task.isCancelled {
                // `if let` rather than `guard let`: a guard binding would live to the end of the
                // loop body and so pin the store across the sleep below, which is what kept an
                // abandoned store — and its network traffic — alive for the full deadline.
                let keepPolling: Bool
                if let store = self {
                    keepPolling = await store.pollStatusOnce(auth: auth, deadline: deadline)
                } else {
                    return
                }
                guard keepPolling else { return }
                try? await Task.sleep(for: interval)
                interval = min(interval * 2, Self.maximumPollInterval)
            }
        }
    }

    /// One status check. Returns whether the conversion is still running and worth polling again.
    private func pollStatusOnce(auth: AuthManager, deadline: Date) async -> Bool {
        do {
            let token = try await auth.validAccessToken()
            if let metadata = try await api.status(urn: exchange.conversionKeyUrn, token: token) {
                switch metadata.status {
                case .completed:
                    await downloadArtifact(metadata: metadata, auth: auth)
                    return false
                case .failed:
                    state = .failed(metadata.error ?? "Conversion failed")
                    return false
                case .running:
                    break
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
        if Date() >= deadline {
            state = .failed("Conversion timed out")
            return false
        }
        return true
    }

    private func downloadArtifact(metadata: ConversionMetadata, auth: AuthManager) async {
        guard let fileName = ConversionAPI.findArtifact(metadata, extension: ".usdz") else {
            state = .failed("No USDz artifact found")
            return
        }
        do {
            let token = try await auth.validAccessToken()
            let downloaded = try await api.downloadArtifact(
                urn: exchange.conversionKeyUrn,
                fileName: fileName,
                token: token
            )
            cachedUSDzURL = try await cache.adopt(downloaded, for: exchange.conversionKeyUrn)
            state = .completed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startLogPollingIfVisible(auth: AuthManager) {
        logTask?.cancel()
        logTask = nil
        guard isLogVisible else { return }
        // Nothing to fetch, and a request would 404: no conversion has ever produced a log.
        if case .notConverted = state { return }

        logTask = Task { [weak self] in
            var interval = Self.initialPollInterval
            while !Task.isCancelled {
                let outcome: LogRefresh
                if let store = self {
                    outcome = await store.refreshLogOnce(auth: auth)
                } else {
                    return
                }
                guard outcome != .finished else { return }
                try? await Task.sleep(for: interval)
                // Only back off while the log is quiet; new output means the conversion is
                // producing something worth following closely.
                interval = outcome == .grew
                    ? Self.initialPollInterval
                    : min(interval * 2, Self.maximumPollInterval)
            }
        }
    }

    private enum LogRefresh {
        case grew
        case unchanged
        /// The log will not grow again, so there is nothing left to poll for.
        case finished
    }

    /// Tails the log once, keeping what has already been received if the request fails. The log
    /// only grows while the conversion runs, so a finished conversion is read exactly once.
    private func refreshLogOnce(auth: AuthManager) async -> LogRefresh {
        var grew = false
        if let token = try? await auth.validAccessToken() {
            let chunk = try? await api.artifactChunk(
                urn: exchange.conversionKeyUrn,
                fileName: "log.txt",
                token: token,
                from: logData.count
            )
            switch chunk {
            case .appended(let data) where !data.isEmpty:
                logData.append(data)
                grew = true
            case .whole(let data) where data != logData:
                logData = data
                grew = true
            case .appended, .whole, .unchanged, .none:
                break
            }
            // Assigned only when the bytes actually changed, so an idle poll doesn't invalidate
            // the sheet and force a re-layout of the whole log.
            if grew {
                logText = String(decoding: logData, as: UTF8.self)
            }
        }
        guard case .running = state else { return .finished }
        return grew ? .grew : .unchanged
    }
}
