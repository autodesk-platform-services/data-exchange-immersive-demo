//
//  ConversionStore.swift
//  DataExchangeViewer
//

import Foundation

enum ConversionState {
    case checking
    case notConverted
    case running(ConversionActivity)
    case completed
    case failed(String)
    /// A conversion exists, but of a version the exchange has since moved past. Distinct from
    /// `notConverted` because the person is told a *newer version was published* rather than that
    /// nothing was ever converted — the service used to report both as a 404.
    case superseded
}

/// What the app is waiting on while a conversion is in flight, so the UI can show something
/// better than an indeterminate "Converting…". The service reports no percentage for the
/// conversion itself, so that phase is reported honestly as elapsed time; the artifact download
/// does have a real byte count, and for a multi-hundred-megabyte BIM export that's the long part.
struct ConversionActivity {
    enum Phase {
        case converting
        case downloading(receivedBytes: Int64, totalBytes: Int64?)
    }

    /// When the service started converting, as the service reports it. Falls back to the moment
    /// the app started waiting for a job it has not yet had a status for — the first `POST`
    /// answers 202 with no body, so the real time arrives with the first poll and replaces this.
    var since: Date
    var phase: Phase = .converting

    /// Progress in 0...1, or nil when it can't be known: throughout the conversion phase, and
    /// for a download the service declares no length for.
    var fractionCompleted: Double? {
        guard case .downloading(let received, let total) = phase, let total, total > 0 else {
            return nil
        }
        return min(1, Double(received) / Double(total))
    }
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

    /// The presigned log URL from the most recent status, when the service supplied one. The log
    /// used to be fetched as an artifact called "log.txt" — a name the app had no business
    /// knowing, and which stopped being in `artifacts` once the log became its own sub-resource.
    private var logURL: String?

    /// Status polling starts fast, because a small conversion can finish in a few seconds, then
    /// backs off so a long BIM conversion isn't polled 100 times.
    private static let initialPollInterval: Duration = .seconds(2)
    private static let maximumPollInterval: Duration = .seconds(15)
    /// How long to keep watching a conversion that reports neither completion nor failure. The
    /// limit used to be five minutes, which a large BIM export can legitimately exceed and which
    /// failed the wait without explaining itself. The wait is now visible and cancellable, so the
    /// deadline only exists to stop polling a service that has quietly stopped making progress.
    private static let pollTimeout: TimeInterval = 30 * 60

    /// The wait currently on screen, so moving from converting to downloading keeps one start
    /// time rather than restarting the elapsed-time readout.
    private var activity: ConversionActivity? {
        if case .running(let activity) = state { return activity }
        return nil
    }

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
        if cache.confirmCached(for: exchange.cacheKeyUrn) {
            cachedUSDzURL = cache.url(for: exchange.cacheKeyUrn)
            state = .completed
            return
        }
        do {
            let token = try await auth.validAccessToken()
            if let metadata = try await api.status(
                urn: exchange.exchangeUrn,
                collectionId: exchange.collectionId,
                token: token
            ) {
                logURL = metadata.logUrl
                switch metadata.status {
                case .completed:
                    await downloadArtifact(metadata: metadata, auth: auth)
                case .running:
                    // The service's own start time, so opening this screen on a conversion someone
                    // else began reports how long it has really been running.
                    state = .running(ConversionActivity(since: metadata.startedOrCreatedAt ?? Date()))
                    startPolling(auth: auth)
                case .failed:
                    state = .failed(metadata.error ?? "The conversion failed on the service.")
                case .superseded:
                    // The cached file was produced from the version that has just been superseded,
                    // so it would preview last week's geometry behind a "ready" badge.
                    cache.delete(for: exchange.cacheKeyUrn)
                    cachedUSDzURL = nil
                    state = .superseded
                }
            } else {
                state = .notConverted
            }
        } catch {
            report(error, auth: auth)
        }
    }

    func convert(auth: AuthManager) async {
        state = .running(ConversionActivity(since: Date()))
        logData = Data()
        logText = ""
        do {
            let token = try await auth.validAccessToken()
            try await api.start(urn: exchange.exchangeUrn, collectionId: exchange.collectionId, token: token)
        } catch ConversionError.conflict {
            // another client already started a conversion; fall through to polling its progress
        } catch {
            report(error, auth: auth)
            return
        }
        startPolling(auth: auth)
        startLogPollingIfVisible(auth: auth)
    }

    /// Abandons the conversion in progress and discards whatever the service has produced for it.
    /// Without this the only way out of a long conversion was to leave the screen, which left it
    /// running on the service with nothing watching.
    func cancel(auth: AuthManager) async {
        stop()
        await clear(auth: auth)
    }

    func clear(auth: AuthManager) async {
        do {
            let token = try await auth.validAccessToken()
            try await api.delete(urn: exchange.exchangeUrn, collectionId: exchange.collectionId, token: token)
            cache.delete(for: exchange.cacheKeyUrn)
            cachedUSDzURL = nil
            logData = Data()
            logText = ""
            state = .notConverted
        } catch {
            report(error, auth: auth)
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
            let deadline = Date().addingTimeInterval(Self.pollTimeout)
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
            let polled = try await api.status(
                urn: exchange.exchangeUrn,
                collectionId: exchange.collectionId,
                token: token
            )
            logURL = polled?.logUrl
            guard let metadata = polled else {
                // The service no longer has a conversion for this exchange, which now means only
                // one thing: another client deleted it. A conversion invalidated by a newly
                // published version arrives as `.superseded` instead of as a 404. Either way
                // there is nothing left to wait for, and polling to the deadline would just spend
                // half an hour on a conversion that is gone.
                state = .notConverted
                return false
            }
            switch metadata.status {
            case .completed:
                await downloadArtifact(metadata: metadata, auth: auth)
                return false
            case .failed:
                state = .failed(metadata.error ?? "The conversion failed on the service.")
                return false
            case .superseded:
                // A new version was published while this conversion was running, so what it is
                // producing is already out of date. Nothing left to wait for.
                state = .superseded
                return false
            case .running:
                // The first POST answers 202 with no body, so the wait starts out measured from
                // this app's clock; the first status that carries a start time corrects it.
                if let since = metadata.startedOrCreatedAt,
                   var activity = self.activity,
                   activity.since != since {
                    activity.since = since
                    state = .running(activity)
                }
            }
        } catch {
            report(error, auth: auth)
            return false
        }
        if Date() >= deadline {
            let minutes = Int(Self.pollTimeout / 60)
            state = .failed(
                """
                The conversion hasn't finished after \(minutes) minutes and may have stopped \
                making progress. Retry to check on it again.
                """
            )
            return false
        }
        return true
    }

    private func downloadArtifact(metadata: ConversionMetadata, auth: AuthManager) async {
        guard let artifact = ConversionAPI.findArtifact(metadata, type: ArtifactType.usdz) else {
            state = .failed("The conversion finished without producing a USDZ file.")
            return
        }
        var activity = self.activity ?? ConversionActivity(since: Date())
        // The service reports the size up front, so the progress bar is determinate from the
        // first byte instead of waiting on a Content-Length to arrive with the response headers.
        activity.phase = .downloading(receivedBytes: 0, totalBytes: artifact.size)
        state = .running(activity)
        do {
            let token = try await auth.validAccessToken()
            // The progress closure captures the store explicitly rather than weakly: it belongs
            // to the URLSession task and is released with it, so it can neither outlive the
            // download nor form a cycle — the store never holds the delegate.
            let downloaded = try await api.downloadArtifact(
                artifact: artifact,
                urn: exchange.exchangeUrn,
                collectionId: exchange.collectionId,
                token: token
            ) { [store = self] received, total in
                // Delivered on URLSession's delegate queue, so this hops back to the actor that
                // owns `state`.
                Task { @MainActor in
                    store.reportDownload(received: received, total: total)
                }
            }
            cachedUSDzURL = try await cache.adopt(downloaded, for: exchange.cacheKeyUrn)
            state = .completed
        } catch {
            report(error, auth: auth)
        }
    }

    /// Puts a failure on screen — and signs out first if it was a rejected token, which no
    /// screen can recover from on its own.
    ///
    /// Cancellation is deliberately not a failure: leaving the detail view cancels an in-flight
    /// status poll or download, and reporting that as "the conversion failed" would be wrong.
    /// Whoever cancelled decides what the state becomes.
    private func report(_ error: Error, auth: AuthManager) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        auth.signOutIfSessionExpired(error)
        state = .failed(error.userFacingDescription)
    }

    /// Updates the byte counts of a download already in progress. Progress callbacks arrive per
    /// chunk — many times a second on a fast connection, each one re-rendering the preview — so
    /// they're coalesced to roughly whole-percent steps, which is all a progress bar can show.
    /// Matching on the existing phase also means a callback that lands after the download
    /// finished or was cancelled can't resurrect the running state.
    private func reportDownload(received: Int64, total: Int64?) {
        guard var activity = self.activity,
              case .downloading(let reported, let declared) = activity.phase else { return }
        // The size the service declared wins over the transfer's own count, which is
        // `NSURLSessionTransferSizeUnknown` for a response without a Content-Length — arriving
        // as nil here, and previously wiping out a total the status had already supplied.
        let total = declared ?? total
        let step = max((total ?? 0) / 100, 1 << 20)
        guard received - reported >= step || received == total else { return }
        activity.phase = .downloading(receivedBytes: received, totalBytes: total)
        state = .running(activity)
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
            let chunk = try? await api.logChunk(
                urn: exchange.exchangeUrn,
                collectionId: exchange.collectionId,
                presignedUrl: logURL,
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
