//
//  AuthModels.swift
//  DataExchangeViewer
//

import Foundation

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct StoredTokens: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

enum AuthError: Error {
    case notAuthenticated
    case missingAuthorizationCode
    case invalidCallbackURL
    case tokenExchangeFailed(Int, String)
}

/// As with `ConversionError`, these descriptions reach the login screen verbatim through
/// `AuthManager.lastError`, so they avoid Foundation's default "error 1" phrasing.
extension AuthError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You're not signed in."
        case .missingAuthorizationCode:
            return "Autodesk didn't return an authorization code."
        case .invalidCallbackURL:
            return "Sign-in was cancelled before it completed."
        case .tokenExchangeFailed(let status, _):
            return "Autodesk rejected the sign-in request (HTTP \(status))."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAuthenticated, .invalidCallbackURL:
            return "Sign in with your Autodesk account to continue."
        case .missingAuthorizationCode, .tokenExchangeFailed:
            return "Try signing in again."
        }
    }
}
