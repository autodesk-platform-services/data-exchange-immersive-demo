//
//  APSConstants.swift
//  DataExchangeViewer
//

import Foundation

enum APSConstants {
    static let authBase = URL(string: "https://developer.api.autodesk.com/authentication/v2")!
    static let clientID = "YmHvRac8ZID6GHVY3R9skAcVZ8joHmyYT1RH7mvic7kEpTM9"
    static let scopes = "data:read viewables:read"
    static let redirectURI = "dxviewer://auth/callback"
    static let callbackURLScheme = "dxviewer"
    static let graphQLEndpoint = URL(string: "https://developer.api.autodesk.com/dataexchange/2023-05/graphql")!
}

enum ConversionServiceConstants {
    // NOTE: SPEC.md names https://data-exchange-immersive-demo.autodesk.io, but that host doesn't
    // have the artifacts produced via the web app — confirmed the web app's actual backend (and
    // where existing conversions live) is this one.
    static let baseURL = URL(string: "https://data-exchange-viewing-service.azurewebsites.net")!
}
