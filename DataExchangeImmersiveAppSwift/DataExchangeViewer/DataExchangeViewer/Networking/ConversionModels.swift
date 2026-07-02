//
//  ConversionModels.swift
//  DataExchangeViewer
//

import Foundation

enum ConversionStatusValue: String, Codable {
    case running
    case completed
    case failed
}

struct ConversionMetadata: Decodable {
    let status: ConversionStatusValue
    let artifacts: [String]
    let error: String?
}

enum ConversionError: Error {
    case unauthorized
    case forbidden
    case conflict
    case http(Int, String)
}
