//
//  ExchangeListView.swift
//  DataExchangeViewer
//

import SwiftUI

struct ExchangeListView: View {
    let project: Project
    @Environment(AuthManager.self) private var auth
    @State private var store = ExchangesStore()

    var body: some View {
        NavigationStack {
            List(store.exchanges) { exchange in
                NavigationLink(exchange.name, value: exchange)
            }
            .navigationDestination(for: Exchange.self) { exchange in
                ExchangeDetailView(exchange: exchange)
            }
            .navigationTitle(project.name)
            .overlay {
                if store.isLoading {
                    ProgressView()
                } else if let error = store.errorMessage {
                    ContentUnavailableView("Failed to load exchanges", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if store.exchanges.isEmpty {
                    ContentUnavailableView("No exchanges in this project", systemImage: "shippingbox")
                }
            }
        }
        .task(id: project.id) {
            await store.load(projectID: project.id, auth: auth)
        }
    }
}
