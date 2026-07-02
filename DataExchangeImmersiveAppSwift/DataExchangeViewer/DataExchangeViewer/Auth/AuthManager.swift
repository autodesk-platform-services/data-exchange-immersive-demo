//
//  AuthManager.swift
//  DataExchangeViewer
//

import Foundation

@Observable
final class AuthManager {
    private(set) var isAuthenticated = false
    private(set) var isBusy = false
    private(set) var lastError: String?

    private let authService = APSAuthService()
    private let tokenStore = TokenStore()
    private var tokens: StoredTokens?
    private var refreshTask: Task<Void, Error>?

    func bootstrap() async {
        guard let stored = tokenStore.load() else { return }
        tokens = stored
        if stored.expiresAt.timeIntervalSinceNow < 60 {
            do {
                try await performRefresh()
            } catch {
                tokenStore.clear()
                tokens = nil
                return
            }
        }
        isAuthenticated = true
    }

    func login() async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            let response = try await authService.authenticate()
            store(response)
            isAuthenticated = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func logout() {
        tokenStore.clear()
        tokens = nil
        isAuthenticated = false
    }

    func validAccessToken() async throws -> String {
        guard let tokens else { throw AuthError.notAuthenticated }
        if tokens.expiresAt.timeIntervalSinceNow < 60 {
            try await performRefresh()
        }
        guard let current = self.tokens else { throw AuthError.notAuthenticated }
        return current.accessToken
    }

    private func performRefresh() async throws {
        if let refreshTask {
            try await refreshTask.value
            return
        }
        guard let refreshToken = tokens?.refreshToken else {
            throw AuthError.notAuthenticated
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.authService.refresh(refreshToken: refreshToken)
                self.store(response)
            } catch {
                self.tokenStore.clear()
                self.tokens = nil
                self.isAuthenticated = false
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func store(_ response: TokenResponse) {
        let stored = StoredTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? tokens?.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
        tokens = stored
        try? tokenStore.save(stored)
    }
}
