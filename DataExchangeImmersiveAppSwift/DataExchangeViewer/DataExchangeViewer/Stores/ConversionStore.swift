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
    private let cache = USDzCache()
    private var pollTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?

    init(exchange: Exchange) {
        self.exchange = exchange
    }

    deinit {
        pollTask?.cancel()
        logTask?.cancel()
    }

    func start(auth: AuthManager) async {
        defer { startLogPolling(auth: auth) }

        if cache.exists(for: exchange.conversionKeyUrn) {
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
        startLogPolling(auth: auth)
    }

    func clear(auth: AuthManager) async {
        do {
            let token = try await auth.validAccessToken()
            try await api.delete(urn: exchange.conversionKeyUrn, token: token)
            cache.delete(for: exchange.conversionKeyUrn)
            cachedUSDzURL = nil
            logText = ""
            state = .notConverted
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startPolling(auth: AuthManager) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(5 * 60)
            while !Task.isCancelled {
                do {
                    let token = try await auth.validAccessToken()
                    if let metadata = try await self.api.status(urn: self.exchange.conversionKeyUrn, token: token) {
                        switch metadata.status {
                        case .completed:
                            await self.downloadArtifact(metadata: metadata, auth: auth)
                            return
                        case .failed:
                            self.state = .failed(metadata.error ?? "Conversion failed")
                            return
                        case .running:
                            break
                        }
                    }
                } catch {
                    self.state = .failed(error.localizedDescription)
                    return
                }
                if Date() >= deadline {
                    self.state = .failed("Conversion timed out")
                    return
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func downloadArtifact(metadata: ConversionMetadata, auth: AuthManager) async {
        guard let fileName = ConversionAPI.findArtifact(metadata, extension: ".usdz") else {
            state = .failed("No USDz artifact found")
            return
        }
        do {
            let token = try await auth.validAccessToken()
            let data = try await api.artifactData(urn: exchange.conversionKeyUrn, fileName: fileName, token: token)
            cachedUSDzURL = try cache.save(data, for: exchange.conversionKeyUrn)
            state = .completed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startLogPolling(auth: AuthManager) {
        logTask?.cancel()
        logTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let token = try? await auth.validAccessToken() {
                    self.logText = (try? await self.api.artifactText(urn: self.exchange.conversionKeyUrn, fileName: "log.txt", token: token)) ?? self.logText
                }
                guard case .running = self.state else { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
