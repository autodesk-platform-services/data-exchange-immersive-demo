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
    @State private var searchText = ""

    private var filteredExchanges: [Exchange] {
        searchText.isEmpty ? exchanges : exchanges.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filteredExchanges) { exchange in
                NavigationLink(value: exchange) {
                    ExchangeRow(exchange: exchange)
                }
            }
            .navigationDestination(for: Exchange.self) { exchange in
                ExchangeDetailView(exchange: exchange)
            }
            .navigationTitle(project.name)
            .searchable(text: $searchText, prompt: "Search exchanges")
            .overlay {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Failed to load exchanges", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await loadExchanges() } }
                    }
                } else if exchanges.isEmpty {
                    ContentUnavailableView("No exchanges in this project", systemImage: "shippingbox")
                }
            }
        }
        .task(id: project.id) { await loadExchanges() }
    }

    private func loadExchanges() async {
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

private struct ExchangeRow: View {
    let exchange: Exchange
    private var isCached: Bool { USDzCache().exists(for: exchange.conversionKeyUrn) }

    var body: some View {
        HStack {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(exchange.name)
                if isCached {
                    Label("Ready to preview", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }
}
