//
//  GraphQLClient.swift
//  DataExchangeViewer
//

import Foundation

/// A connection in the Data Exchange schema: one page of `results` plus the cursor for the next.
struct Results<T: Decodable>: Decodable {
    let results: [T]
    /// Absent on the last page, and on the nested `Exchanges` connections that the app reads
    /// without asking for it.
    let pagination: Pagination?

    struct Pagination: Decodable {
        /// Points at the *next* page, and is null once there isn't one.
        let cursor: String?
    }

    var nextCursor: String? { pagination?.cursor }
    /// Whether the service split this connection across pages. Used where the schema exposes no
    /// pagination argument to follow the cursor with, so the truncation can at least be reported.
    var isTruncated: Bool { nextCursor != nil }
}

enum GraphQLError: Error {
    case http(Int, String)
    case graphQL([String])
    case noData
}

struct GraphQLClient {
    /// Stops a service that keeps returning the same or an endless cursor from spinning forever.
    /// Far beyond any real hub, project, or folder listing.
    private static let maximumPages = 200

    private struct Envelope<T: Decodable>: Decodable {
        let data: T?
        let errors: [GraphQLErrorMessage]?
    }
    private struct GraphQLErrorMessage: Decodable {
        let message: String
    }
    private struct RequestBody: Encodable {
        let query: String
        /// Every identifier this app sends travels as a GraphQL variable rather than being
        /// interpolated into the query text. All of them are strings (`ID` and `String` are both
        /// string-serialized scalars), and a nil value encodes as JSON null — which is what the
        /// schema's nullable `PaginationInput.cursor` wants for "give me the first page".
        let variables: [String: String?]?
    }

    func execute<T: Decodable>(
        _ query: String,
        variables: [String: String?]? = nil,
        token: String
    ) async throws -> T {
        var request = URLRequest(url: APSConstants.graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(query: query, variables: variables))

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

    /// Runs a query once per page, following `pagination { cursor }` until the service stops
    /// handing one back, and returns every result across every page.
    ///
    /// The query must declare a `$cursor: String` variable and pass it as the `cursor` of its
    /// `PaginationInput`; `connection` then points at the connection to page through.
    func paginate<Payload: Decodable, Item: Decodable>(
        _ query: String,
        variables: [String: String?] = [:],
        token: String,
        connection: (Payload) -> Results<Item>?
    ) async throws -> [Item] {
        var items: [Item] = []
        var cursor: String?
        for _ in 0..<Self.maximumPages {
            var pageVariables = variables
            pageVariables["cursor"] = cursor
            let payload: Payload = try await execute(query, variables: pageVariables, token: token)
            guard let page = connection(payload) else { break }
            items.append(contentsOf: page.results)
            // A service that echoes the cursor it was just given would otherwise loop until the
            // page budget ran out, refetching the same page each time.
            guard let next = page.nextCursor, next != cursor else { break }
            cursor = next
        }
        return items
    }
}

/// The hub, project, and exchange lists all report failures by showing `localizedDescription`,
/// so these are the messages behind "Failed to load hubs" and its siblings.
extension GraphQLError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .http(401, _):
            return "Your session expired."
        case .http(403, _):
            return "You don't have access to this data."
        case .http(let status, _):
            return "Autodesk Data Exchange returned an unexpected response (HTTP \(status))."
        // The service reports several messages for one query; the first is the actionable one
        // and the rest are usually the same failure restated per field.
        case .graphQL(let messages):
            return messages.first ?? "Autodesk Data Exchange reported an error."
        case .noData:
            return "Autodesk Data Exchange returned no data."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .http(401, _):
            return "Sign in again to continue."
        case .http(403, _):
            return "Ask the hub or project administrator to grant you access."
        case .http, .graphQL, .noData:
            return "Try again in a moment."
        }
    }
}
