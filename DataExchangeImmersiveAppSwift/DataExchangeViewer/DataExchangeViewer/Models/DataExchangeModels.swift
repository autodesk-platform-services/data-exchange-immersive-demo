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
    let fileUrn: String
    let fileVersionUrn: String

    var conversionKeyUrn: String { fileUrn }
    var viewerPreferredUrn: String { fileVersionUrn.isEmpty ? fileUrn : fileVersionUrn }
}
