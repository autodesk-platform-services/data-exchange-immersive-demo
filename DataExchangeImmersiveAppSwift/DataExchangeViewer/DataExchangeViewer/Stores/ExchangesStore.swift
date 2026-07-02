//
//  ExchangesStore.swift
//  DataExchangeViewer
//

import Foundation

@Observable
final class ExchangesStore {
    private(set) var exchanges: [Exchange] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let api = DataExchangeAPI()

    func load(projectID: String, auth: AuthManager) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let token = try await auth.validAccessToken()
            exchanges = try await api.exchanges(token: token, projectId: projectID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
