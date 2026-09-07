//
//  APSConstants.swift
//  DataExchangeViewer
//

import Foundation

enum APSConstants {
    static let authBase = URL(string: "https://developer.api.autodesk.com/authentication/v2")!
    static let graphQLEndpoint = URL(string: "https://developer.api.autodesk.com/dataexchange/2023-05/graphql")!

    /// A public PKCE client, so shipping it is not a leaked secret — but it is still the one piece
    /// of configuration that has to change to run the app against your own APS application.
    static let clientID = AppConfiguration.string(
        "APSClientID",
        default: "YmHvRac8ZID6GHVY3R9skAcVZ8joHmyYT1RH7mvic7kEpTM9"
    )

    static let scopes = AppConfiguration.string("APSScopes", default: "data:read viewables:read")

    /// Must match the custom scheme registered in `CFBundleURLTypes`, which reads the same build
    /// setting, and the callback URL registered on the APS application.
    static let callbackURLScheme = AppConfiguration.string("APSCallbackURLScheme", default: "dxviewer")

    static var redirectURI: String { "\(callbackURLScheme)://auth/callback" }
}

enum ConversionServiceConstants {
    /// Overridable so the app can be pointed at a conversion service running on your own machine
    /// without editing source. Note that the app forwards the signed-in user's APS access token to
    /// whatever host this names — see the README.
    static let baseURL = AppConfiguration.url(
        "ConversionServiceBaseURL",
        default: "https://data-exchange-conversion-service.azurewebsites.net"
    )
}

/// Build-time configuration, read from `Info.plist`.
///
/// Each key is populated from a build setting of the same name in the target's `Info.plist`, so
/// pointing the app at a locally running conversion service or a different APS application is a
/// build setting — an xcconfig entry, or `xcodebuild CONVERSION_SERVICE_BASE_URL=http://localhost:5000`
/// — rather than a source edit.
///
/// A missing, empty, or unexpanded value falls back to the shipped default rather than trapping: a
/// build with one setting mistyped should still run against the public demo service, and say so
/// through the value it used rather than through a crash on launch.
enum AppConfiguration {
    static func string(_ key: String, default fallback: String) -> String {
        resolve(Bundle.main.object(forInfoDictionaryKey: key) as? String, default: fallback)
    }

    static func url(_ key: String, default fallback: String) -> URL {
        url(from: string(key, default: fallback), default: fallback)
    }

    /// The decision itself, split from the `Bundle` lookup so `AppConfigurationTests` can check it
    /// without a bundle whose `Info.plist` it would have to build first.
    static func resolve(_ value: String?, default fallback: String) -> String {
        guard let value,
              !value.isEmpty,
              // An undefined build setting reaches Info.plist as the literal "$(NAME)".
              !value.hasPrefix("$(") else {
            return fallback
        }
        return value
    }

    /// A base URL the app can actually send a request to, or the shipped default.
    ///
    /// The scheme and host are checked rather than just parseability: `URL(string:)` accepts a
    /// string with neither as a *relative* URL, so an override written as `localhost:5000` would
    /// otherwise be adopted and then produce requests to nowhere. This one is worth being strict
    /// about — it names the host the app forwards the signed-in user's APS token to.
    static func url(from raw: String, default fallback: String) -> URL {
        // The fallback is a literal at every call site, so force-unwrapping it is safe; a
        // malformed override falls back to it instead of trapping.
        let fallbackURL = URL(string: fallback)!
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host()?.isEmpty == false else {
            return fallbackURL
        }
        return url
    }
}
