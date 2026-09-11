//
//  ExchangeListView.swift
//  DataExchangeViewer
//

import SwiftUI

struct ExchangeListView: View {
    let project: Project
    @Environment(AuthManager.self) private var auth
    @State private var listing: LoadState<ExchangeListing> = .loading
    @State private var searchText = ""
    /// The cache's own in-memory index, so a row answers "is this cached?" without a `fileExists`
    /// probe per visible row, per body evaluation, on the main thread. The index is observable, so
    /// rows still update the moment a conversion finishes downloading.
    private let cache = USDzCache.shared

    private var filteredExchanges: [Exchange] {
        let loaded = listing.value?.exchanges ?? []
        return searchText.isEmpty ? loaded : loaded.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// The `NavigationStack` is required, not redundant with the enclosing `NavigationSplitView`.
    /// This view is that split view's detail column, and a `navigationDestination` declared on a
    /// column targets the *next* column — of which there is none after detail, so the link has
    /// nowhere to push and silently does nothing. A stack inside the column is what gives it
    /// somewhere to push, and it keeps the destination next to the `NavigationLink` that uses it.
    var body: some View {
        NavigationStack {
            List {
                if let loaded = listing.value, !loaded.isComplete {
                    Section { incompleteListingNotice(loaded) }
                }
                ForEach(filteredExchanges) { exchange in
                    NavigationLink(value: exchange) {
                        ExchangeRow(
                            exchange: exchange,
                            isCached: cache.isCached(for: exchange.cacheKeyUrn)
                        )
                    }
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

    /// Says so when the walk of the project's folders couldn't reach everything, rather than
    /// letting a partial list read as the whole project. The rows that *were* found are still
    /// listed above it — a partial answer is useful as long as it isn't presented as complete.
    @ViewBuilder
    private func incompleteListingNotice(_ listing: ExchangeListing) -> some View {
        let folders = listing.partialFolders
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("This list may be incomplete.")
                if !folders.isEmpty {
                    Text("Autodesk Data Exchange returned only the first page of exchanges for \(folders.formatted(.list(type: .and))).")
                }
                if listing.reachedFolderLimit {
                    Text("The project has more folders than this app searches, so deeper folders were skipped.")
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// As in the sidebar, "No exchanges in this project" is only reachable from `.loaded`. The
    /// state starting at `.loading` also keeps that message from flashing up on first render and
    /// on every project switch.
    @ViewBuilder
    private var exchangeListStatus: some View {
        switch listing {
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
            if loaded.exchanges.isEmpty {
                if loaded.isComplete {
                    ContentUnavailableView("No exchanges in this project", systemImage: "shippingbox")
                } else {
                    // "None" and "none that this app could reach" are different answers, and the
                    // second one has a retry worth offering.
                    ContentUnavailableView {
                        Label("No exchanges found", systemImage: "shippingbox")
                    } description: {
                        Text("Parts of this project couldn't be searched, so it may contain exchanges this list doesn't show.")
                    } actions: {
                        Button("Retry") { Task { await loadExchanges() } }
                    }
                }
            } else if filteredExchanges.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func loadExchanges() async {
        listing = .loading
        do {
            let token = try await auth.validAccessToken()
            listing = .loaded(try await DataExchangeAPI().exchanges(token: token, projectId: project.id))
        } catch {
            auth.signOutIfSessionExpired(error)
            listing = .failed(error.userFacingDescription)
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
