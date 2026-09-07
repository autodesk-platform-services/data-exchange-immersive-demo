//
//  AppConfigurationTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
@testable import DataExchangeViewer

/// Build settings reach the app through `Info.plist`, where a mistyped or undefined setting
/// arrives as an empty string or as the literal `$(NAME)`. Either has to fall back to the shipped
/// default rather than pointing the app at nothing.
@Suite("App configuration")
struct AppConfigurationTests {
    @Test func usesAnOverrideWhenOneIsSet() {
        #expect(AppConfiguration.resolve("http://localhost:5000", default: "https://example.com")
            == "http://localhost:5000")
    }

    @Test(arguments: [nil, "", "$(CONVERSION_SERVICE_BASE_URL)"] as [String?])
    func fallsBackForAMissingOrUnexpandedSetting(value: String?) {
        #expect(AppConfiguration.resolve(value, default: "https://example.com") == "https://example.com")
    }

    @Test func parsesAnOverriddenURL() {
        #expect(
            AppConfiguration.url(from: "http://localhost:5000", default: "https://example.com")
                == URL(string: "http://localhost:5000")
        )
    }

    /// A malformed override falls back instead of trapping: a build with one setting wrong should
    /// still launch against the public demo service.
    ///
    /// `URL(string:)` alone is not enough of a check. It accepts `localhost:5000` and `not a url`
    /// as relative URLs, and adopting one of those would leave the app issuing requests to
    /// nowhere with no indication of why.
    @Test(arguments: [
        "not a url",
        "localhost:5000",
        "data-exchange-conversion-service.azurewebsites.net",
        "http://exa mple.com",
        "ftp://example.com",
        "file:///tmp",
    ])
    func fallsBackForAnUnusableURL(raw: String) {
        #expect(AppConfiguration.url(from: raw, default: "https://example.com") == URL(string: "https://example.com"))
    }

    @Test(arguments: ["http://localhost:5000", "https://example.com/api", "HTTPS://Example.com"])
    func acceptsAnyHTTPOverride(raw: String) {
        #expect(AppConfiguration.url(from: raw, default: "https://fallback.example") == URL(string: raw))
    }

    /// The shipped defaults themselves have to be usable, since every one of them is what an
    /// unconfigured build runs with.
    @Test func shippedDefaultsAreUsable() {
        #expect(!APSConstants.clientID.isEmpty)
        #expect(APSConstants.scopes.contains("data:read"))
        #expect(!APSConstants.callbackURLScheme.contains(":"))
        #expect(APSConstants.redirectURI.hasSuffix("://auth/callback"))
        #expect(ConversionServiceConstants.baseURL.scheme?.hasPrefix("http") == true)
        #expect(ConversionServiceConstants.baseURL.host() != nil)
    }
}
