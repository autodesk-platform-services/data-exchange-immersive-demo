//
//  ExchangeListView.swift
//  DataExchangeViewer
//

import SwiftUI

struct ExchangeListView: View {
    let project: Project
    @Environment(AuthManager.self) private var auth
    @State private var exchanges: [Exchange] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List(exchanges) { exchange in
                NavigationLink(exchange.name, value: exchange)
            }
            .navigationDestination(for: Exchange.self) { exchange in
                ExchangeDetailView(exchange: exchange)
            }
            .navigationTitle(project.name)
            .overlay {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableView("Failed to load exchanges", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if exchanges.isEmpty {
                    ContentUnavailableView("No exchanges in this project", systemImage: "shippingbox")
                }
            }
        }
        .task(id: project.id) {
            isLoading = true
            errorMessage = nil
            defer { isLoading = false }
            do {
                let token = try await auth.validAccessToken()
                exchanges = try await DataExchangeAPI().exchanges(token: token, projectId: project.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
