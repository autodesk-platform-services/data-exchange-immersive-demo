//
//  GraphQLClient.swift
//  DataExchangeViewer
//

import Foundation

struct Results<T: Decodable>: Decodable {
    let results: [T]
}

enum GraphQLError: Error {
    case http(Int, String)
    case graphQL([String])
    case noData
}

struct GraphQLClient {
    private struct Envelope<T: Decodable>: Decodable {
        let data: T?
        let errors: [GraphQLErrorMessage]?
    }
    private struct GraphQLErrorMessage: Decodable {
        let message: String
    }
    private struct RequestBody: Encodable {
        let query: String
    }

    func execute<T: Decodable>(_ query: String, token: String) async throws -> T {
        var request = URLRequest(url: APSConstants.graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(query: query))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GraphQLError.http(status, String(data: data, encoding: .utf8) ?? "")
        }

        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let errors = envelope.errors, !errors.isEmpty {
            throw GraphQLError.graphQL(errors.map(\.message))
        }
        guard let payload = envelope.data else {
            throw GraphQLError.noData
        }
        return payload
    }
}
