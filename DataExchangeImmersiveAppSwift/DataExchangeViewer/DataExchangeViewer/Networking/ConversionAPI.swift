//
//  ConversionAPI.swift
//  DataExchangeViewer
//

import Foundation

struct ConversionAPI {
    private static let pathSegmentAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private func endpoint(urn: String) -> URL {
        // `appendingPathComponent` would double-encode an already percent-encoded segment
        // (it treats '%' itself as a character needing escaping), so the URL is built from
        // a raw string instead of layering `appendingPathComponent` on top of `encoded`.
        let encoded = urn.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? urn
        let urlString = ConversionServiceConstants.baseURL.absoluteString + "/api/exchanges/" + encoded
        return URL(string: urlString)!
    }

    func status(urn: String, token: String) async throws -> ConversionMetadata? {
        var request = URLRequest(url: endpoint(urn: urn))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 404: return nil
        case 200: return try JSONDecoder().decode(ConversionMetadata.self, from: data)
        case 401: throw ConversionError.unauthorized
        case 403: throw ConversionError.forbidden
        default: throw ConversionError.http(http?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
    }

    func start(urn: String, token: String) async throws {
        var request = URLRequest(url: endpoint(urn: urn))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 202: return
        case 409: throw ConversionError.conflict
        case 401: throw ConversionError.unauthorized
        case 403: throw ConversionError.forbidden
        default: throw ConversionError.http(http?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
    }

    func delete(urn: String, token: String) async throws {
        var request = URLRequest(url: endpoint(urn: urn))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 200: return
        case 401: throw ConversionError.unauthorized
        case 403: throw ConversionError.forbidden
        default: throw ConversionError.http(http?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
    }

    func artifactData(urn: String, fileName: String, token: String) async throws -> Data {
        var request = URLRequest(url: endpoint(urn: urn).appendingPathComponent(fileName))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            switch http?.statusCode {
            case 401: throw ConversionError.unauthorized
            case 403: throw ConversionError.forbidden
            default: throw ConversionError.http(http?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
            }
        }
        return data
    }

    func artifactText(urn: String, fileName: String, token: String) async throws -> String {
        let data = try await artifactData(urn: urn, fileName: fileName, token: token)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func findArtifact(_ metadata: ConversionMetadata?, extension ext: String) -> String? {
        metadata?.artifacts.first { $0.hasSuffix(ext) }
    }
}
