//
//  DataExchangeModels.swift
//  DataExchangeViewer
//

import Foundation

struct Hub: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
}

struct Project: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
}

struct Exchange: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    /// Data Exchange collection ID. For ACC exchanges this is the project ID supplied to the
    /// GraphQL listing query; SDK v8 requires it together with the exchange URN.
    let collectionId: String
    /// Lineage URN — the exchange's version-independent identity.
    let fileUrn: String
    /// URN of the specific published version this listing describes. Empty when the API reported
    /// no version for the exchange.
    let fileVersionUrn: String

    /// What the conversion service is asked about. Version-agnostic on purpose: the service
    /// resolves the exchange through the Data Exchange SDK using the collection ID and a
    /// `dm.lineage` URN, so a version URN cannot be substituted here. The service compares the version it
    /// converted against the exchange's current one and reports a conversion made from an older
    /// version as absent.
    var exchangeUrn: String { fileUrn }

    /// Key for the on-device USDZ cache. Version-specific, so publishing a new version of an
    /// exchange cannot leave the app serving last week's geometry behind a green "Ready to preview"
    /// badge. Falls back to the lineage URN when no version is known.
    var cacheKeyUrn: String { fileVersionUrn.isEmpty ? fileUrn : fileVersionUrn }
}
