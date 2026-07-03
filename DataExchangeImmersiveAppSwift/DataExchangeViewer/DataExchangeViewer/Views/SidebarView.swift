//
//  SidebarView.swift
//  DataExchangeViewer
//

import SwiftUI

struct SidebarView: View {
    @Environment(AuthManager.self) private var auth
    @Binding var selectedProject: Project?
    @State private var hubs: [Hub] = []
    @State private var projectsByHub: [String: [Project]] = [:]
    @State private var loadingHubIDs: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(hubs) { hub in
                HubRow(
                    hub: hub,
                    projects: projectsByHub[hub.id],
                    isLoading: loadingHubIDs.contains(hub.id),
                    selectedProject: $selectedProject,
                    onExpand: { await loadProjectsIfNeeded(hubID: hub.id) }
                )
            }
        }
        .overlay {
            if hubs.isEmpty {
                if let errorMessage {
                    ContentUnavailableView("Failed to load hubs", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
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
            do {
                hubs = try await DataExchangeAPI().hubs(token: token)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadProjectsIfNeeded(hubID: String) async {
        guard projectsByHub[hubID] == nil, !loadingHubIDs.contains(hubID),
              let token = try? await auth.validAccessToken() else { return }
        loadingHubIDs.insert(hubID)
        defer { loadingHubIDs.remove(hubID) }
        do {
            projectsByHub[hubID] = try await DataExchangeAPI().projects(token: token, hubId: hubID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HubRow: View {
    let hub: Hub
    let projects: [Project]?
    let isLoading: Bool
    @Binding var selectedProject: Project?
    let onExpand: () async -> Void
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isLoading {
                ProgressView()
            } else if let projects {
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
            guard isExpanded else { return }
            await onExpand()
        }
    }
}
