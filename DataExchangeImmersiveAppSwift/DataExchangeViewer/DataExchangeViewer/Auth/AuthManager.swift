//
//  AuthManager.swift
//  DataExchangeViewer
//

import Foundation
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

@Observable
final class AuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    private(set) var isAuthenticated = false
    private(set) var isBusy = false
    private(set) var lastError: String?

    private let tokenStore = TokenStore()
    private var tokens: StoredTokens?
    private var refreshTask: Task<Void, Error>?
    private var session: ASWebAuthenticationSession?

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
            let response = try await authenticate()
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
                let response = try await self.refresh(refreshToken: refreshToken)
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

    // MARK: - OAuth PKCE (APS authorization code flow)

    private func authenticate() async throws -> TokenResponse {
        let verifier = PKCE.codeVerifier()
        let challenge = PKCE.codeChallenge(for: verifier)

        var components = URLComponents(url: APSConstants.authBase.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: APSConstants.clientID),
            URLQueryItem(name: "redirect_uri", value: APSConstants.redirectURI),
            URLQueryItem(name: "scope", value: APSConstants.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: APSConstants.callbackURLScheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? AuthError.invalidCallbackURL)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.missingAuthorizationCode
        }

        return try await exchange(code: code, verifier: verifier)
    }

    private func exchange(code: String, verifier: String) async throws -> TokenResponse {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: APSConstants.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: APSConstants.redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]
        return try await postToken(body: body)
    }

    private func refresh(refreshToken: String) async throws -> TokenResponse {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: APSConstants.clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "scope", value: APSConstants.scopes)
        ]
        return try await postToken(body: body)
    }

    private func postToken(body: URLComponents) async throws -> TokenResponse {
        var request = URLRequest(url: APSConstants.authBase.appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = (body.percentEncodedQuery ?? "").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.tokenExchangeFailed(status, String(data: data, encoding: .utf8) ?? "")
        }
        let decoder = JSONDecoder()
        return try decoder.decode(TokenResponse.self, from: data)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
