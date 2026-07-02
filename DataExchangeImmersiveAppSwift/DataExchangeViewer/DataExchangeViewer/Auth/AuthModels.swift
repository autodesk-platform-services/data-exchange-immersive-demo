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
