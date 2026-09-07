//
//  PKCE.swift
//  DataExchangeViewer
//

import Foundation
import CryptoKit
import Security

enum PKCE {
    /// Why a code verifier could not be produced. Worth a real error rather than a silent
    /// degradation: `SecRandomCopyBytes` leaves the buffer it was given untouched on failure, so
    /// discarding the status would hand APS an all-zeros verifier — a security primitive quietly
    /// producing a constant.
    enum PKCEError: Error {
        case randomBytesUnavailable(OSStatus)
    }

    static func codeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PKCEError.randomBytesUnavailable(status)
        }
        return base64URLEncode(Data(bytes))
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Surfaced on the login screen, which reports `userFacingDescription` for whatever sign-in threw.
extension PKCE.PKCEError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .randomBytesUnavailable(let status):
            return "This device could not generate the random data needed to sign in securely (status \(status))."
        }
    }

    var recoverySuggestion: String? {
        "Try again in a moment."
    }
}
