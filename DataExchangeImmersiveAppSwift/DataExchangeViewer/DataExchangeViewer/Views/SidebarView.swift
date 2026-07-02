//
//  SidebarView.swift
//  DataExchangeViewer
//

import SwiftUI

struct SidebarView: View {
    @Environment(AuthManager.self) private var auth
    @Binding var selectedProject: Project?
    @State private var store = HubsProjectsStore()

    var body: some View {
        List {
            ForEach(store.hubs) { hub in
                HubRow(hub: hub, store: store, selectedProject: $selectedProject)
            }
        }
        .overlay {
            if store.hubs.isEmpty {
                if let error = store.errorMessage {
                    ContentUnavailableView("Failed to load hubs", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ContentUnavailableView("No hubs found", systemImage: "building.2")
                }
            }
        }
        .navigationTitle("Data Exchange Viewer")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Logout") { auth.logout() }
            }
        }
        .task {
            guard let token = try? await auth.validAccessToken() else { return }
            await store.loadHubs(token: token)
        }
    }
}

private struct HubRow: View {
    let hub: Hub
    let store: HubsProjectsStore
    @Binding var selectedProject: Project?
    @Environment(AuthManager.self) private var auth
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if store.loadingHubIDs.contains(hub.id) {
                ProgressView()
            } else if let projects = store.projectsByHub[hub.id] {
                if projects.isEmpty {
                    Text("No projects").foregroundStyle(.secondary)
                } else {
                    ForEach(projects) { project in
                        Button {
                            selectedProject = project
                        } label: {
                            Text(project.name)
                        }
                    }
                }
            }
        } label: {
            Text(hub.name)
        }
        .task(id: isExpanded) {
            guard isExpanded, let token = try? await auth.validAccessToken() else { return }
            await store.loadProjectsIfNeeded(hubID: hub.id, token: token)
        }
    }
}
