//
//  ExchangeListView.swift
//  DataExchangeViewer
//

import SwiftUI

struct ExchangeListView: View {
    let project: Project
    @Environment(AuthManager.self) private var auth
    @State private var exchanges: LoadState<[Exchange]> = .loading
    @State private var searchText = ""

    private var filteredExchanges: [Exchange] {
        let loaded = exchanges.value ?? []
        return searchText.isEmpty ? loaded : loaded.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
            .overlay { exchangeListStatus }
        }
        .task(id: project.id) { await loadExchanges() }
    }

    /// As in the sidebar, "No exchanges in this project" is only reachable from `.loaded`. The
    /// state starting at `.loading` also removes the flash of that message on first render and
    /// on every project switch, which the previous `isLoading = false` default allowed.
    @ViewBuilder
    private var exchangeListStatus: some View {
        switch exchanges {
        case .loading:
            ProgressView("Loading exchanges")

        case .failed(let message):
            ContentUnavailableView {
                Label("Failed to load exchanges", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await loadExchanges() } }
            }

        case .loaded(let loaded):
            if loaded.isEmpty {
                ContentUnavailableView("No exchanges in this project", systemImage: "shippingbox")
            } else if filteredExchanges.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func loadExchanges() async {
        exchanges = .loading
        do {
            let token = try await auth.validAccessToken()
            exchanges = .loaded(try await DataExchangeAPI().exchanges(token: token, projectId: project.id))
        } catch {
            exchanges = .failed(error.localizedDescription)
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
