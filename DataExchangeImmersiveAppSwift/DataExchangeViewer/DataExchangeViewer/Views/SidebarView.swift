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
    @State private var hubListErrorMessage: String?
    @State private var hubProjectErrors: [String: String] = [:]
    @State private var hubListRetryToken = UUID()
    @State private var searchText = ""

    private var filteredHubs: [Hub] {
        searchText.isEmpty ? hubs : hubs.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filteredHubs) { hub in
                HubRow(
                    hub: hub,
                    projects: projectsByHub[hub.id],
                    isLoading: loadingHubIDs.contains(hub.id),
                    errorMessage: hubProjectErrors[hub.id],
                    selectedProject: $selectedProject,
                    onExpand: { await loadProjectsIfNeeded(hubID: hub.id) }
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search hubs")
        .overlay {
            if hubs.isEmpty {
                if let hubListErrorMessage {
                    ContentUnavailableView {
                        Label("Failed to load hubs", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(hubListErrorMessage)
                    } actions: {
                        Button("Retry") { hubListRetryToken = UUID() }
                    }
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
        .task(id: hubListRetryToken) {
            hubListErrorMessage = nil
            guard let token = try? await auth.validAccessToken() else { return }
            do {
                hubs = try await DataExchangeAPI().hubs(token: token)
            } catch {
                hubListErrorMessage = error.localizedDescription
            }
        }
    }

    private func loadProjectsIfNeeded(hubID: String) async {
        guard projectsByHub[hubID] == nil, !loadingHubIDs.contains(hubID),
              let token = try? await auth.validAccessToken() else { return }
        loadingHubIDs.insert(hubID)
        hubProjectErrors[hubID] = nil
        defer { loadingHubIDs.remove(hubID) }
        do {
            projectsByHub[hubID] = try await DataExchangeAPI().projects(token: token, hubId: hubID)
        } catch {
            hubProjectErrors[hubID] = error.localizedDescription
        }
    }
}

private struct HubRow: View {
    let hub: Hub
    let projects: [Project]?
    let isLoading: Bool
    let errorMessage: String?
    @Binding var selectedProject: Project?
    let onExpand: () async -> Void
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") { Task { await onExpand() } }
                }
            } else if let projects {
                if projects.isEmpty {
                    Text("No projects").foregroundStyle(.secondary)
                } else {
                    ForEach(projects) { project in
                        Button {
                            selectedProject = project
                        } label: {
                            Label(project.name, systemImage: "folder")
                        }
                    }
                }
            }
        } label: {
            HStack {
                Label(hub.name, systemImage: "building.2")
                if let projects {
                    Spacer()
                    Text("\(projects.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: isExpanded) {
            guard isExpanded else { return }
            await onExpand()
        }
    }
}
