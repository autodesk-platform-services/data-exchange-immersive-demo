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

/// One file produced by a conversion.
///
/// The service describes each artifact rather than just naming it, so the app selects the model it
/// wants by `type` instead of matching a file-name suffix, and knows the download size before the
/// first byte arrives.
struct ConversionArtifact: Decodable, Equatable {
    let name: String
    let type: String
    let contentType: String
    let size: Int64
    let checksum: String?
}

struct ConversionMetadata: Decodable {
    let status: ConversionStatusValue
    let artifacts: [ConversionArtifact]
    let error: String?
}

/// The artifact types the app looks for. The service can produce others (`obj`, `mtl`, `log`);
/// these are the ones the app has a use for.
enum ArtifactType {
    static let usdz = "usdz"
}

enum ConversionError: Error {
    case unauthorized
    case forbidden
    case conflict
    case http(Int, String)
}

/// `localizedDescription` is shown directly in the UI on every conversion failure path, and for a
/// plain `Error` Foundation renders that as "The operation couldn't be completed.
/// (DataExchangeViewer.ConversionError error 1.)". These strings are what the person actually
/// reads, so they say what happened and — where there is one — what to do about it.
extension ConversionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Your session expired."
        case .forbidden:
            return "You don't have access to this exchange."
        case .conflict:
            return "This exchange is already being converted."
        case .http(let status, let body):
            let detail = Self.detail(fromResponseBody: body)
            return detail.map { "The conversion service returned an error: \($0)" }
                ?? "The conversion service returned an unexpected response (HTTP \(status))."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unauthorized:
            return "Sign in again to continue."
        case .forbidden:
            return "Ask the project administrator to grant you access, then try again."
        case .conflict:
            return "Wait for the conversion in progress to finish."
        case .http:
            return "Check that the conversion service is running, then try again."
        }
    }

    /// The service answers with an RFC 9457 problem document, so its `detail` is a sentence
    /// written for a person. Falls back to nil rather than to the raw body, which for an
    /// unexpected failure can be a whole HTML error page.
    private static func detail(fromResponseBody body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let problem = try? JSONDecoder().decode(ProblemDetails.self, from: data) else {
            return nil
        }
        return problem.detail ?? problem.title
    }

    private struct ProblemDetails: Decodable {
        let title: String?
        let detail: String?
    }
}
