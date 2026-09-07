//
//  PKCETests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
@testable import DataExchangeViewer

@Suite("PKCE")
struct PKCETests {
    /// 32 random bytes, base64url-encoded without padding — 43 characters, inside RFC 7636's
    /// 43...128 range for a code verifier.
    @Test func verifierHasTheLengthTheRFCRequires() throws {
        let verifier = try PKCE.codeVerifier()
        #expect(verifier.count == 43)
        #expect((43...128).contains(verifier.count))
    }

    /// RFC 7636 restricts the verifier to unreserved characters. A '+', '/', or '=' left over from
    /// plain base64 would be re-encoded in transit and no longer match the challenge.
    @Test func verifierUsesOnlyUnreservedCharacters() throws {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for _ in 0..<32 {
            let verifier = try PKCE.codeVerifier()
            #expect(verifier.allSatisfy { unreserved.contains($0) }, "unexpected character in \(verifier)")
        }
    }

    /// The whole point of the verifier is that it is unpredictable. `SecRandomCopyBytes` leaves its
    /// buffer untouched on failure, so a discarded status would show up here as a constant.
    @Test func verifiersAreDistinct() throws {
        var seen: Set<String> = []
        for _ in 0..<64 {
            seen.insert(try PKCE.codeVerifier())
        }
        #expect(seen.count == 64)
        #expect(!seen.contains(String(repeating: "A", count: 43)))
    }

    /// The test vector from RFC 7636 appendix B. This is the one value APS also computes, so it
    /// pins the SHA-256-then-base64url pipeline end to end.
    @Test func challengeMatchesTheRFCTestVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.codeChallenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func challengeIsBase64URLWithoutPadding() throws {
        let challenge = PKCE.codeChallenge(for: try PKCE.codeVerifier())
        // A SHA-256 digest is 32 bytes, which base64-encodes to 43 characters plus one '=' pad.
        #expect(challenge.count == 43)
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }

    @Test func challengeIsDeterministic() {
        #expect(PKCE.codeChallenge(for: "verifier") == PKCE.codeChallenge(for: "verifier"))
        #expect(PKCE.codeChallenge(for: "verifier") != PKCE.codeChallenge(for: "verifier2"))
    }
}
