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
    /// The cache's own in-memory index. Rows used to answer "is this cached?" with a
    /// `USDzCache()` initialization (which creates the cache directory) plus a `fileExists`
    /// probe — two syscalls per visible row, per body evaluation, on the main thread. Because the
    /// index is observable, rows still update the moment a conversion finishes downloading.
    private let cache = USDzCache.shared

    private var filteredExchanges: [Exchange] {
        let loaded = exchanges.value ?? []
        return searchText.isEmpty ? loaded : loaded.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filteredExchanges) { exchange in
                NavigationLink(value: exchange) {
                    ExchangeRow(
                        exchange: exchange,
                        isCached: cache.isCached(for: exchange.conversionKeyUrn)
                    )
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
        .task { await cache.loadIndexIfNeeded() }
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
    let isCached: Bool

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
