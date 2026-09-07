//
//  SidebarView.swift
//  DataExchangeViewer
//

import SwiftUI

struct SidebarView: View {
    @Environment(AuthManager.self) private var auth
    @Binding var selectedProject: Project?
    @State private var hubs: LoadState<[Hub]> = .loading
    @State private var projectsByHub: [String: [Project]] = [:]
    @State private var loadingHubIDs: Set<String> = []
    @State private var hubProjectErrors: [String: String] = [:]
    @State private var hubListRetryToken = UUID()
    @State private var searchText = ""
    /// Downloaded USDZ packages are hundreds of megabytes each, so how much disk the app is
    /// holding is worth showing — and worth being able to reclaim without deleting the app.
    private let cache = USDzCache.shared

    private var filteredHubs: [Hub] {
        let loaded = hubs.value ?? []
        return searchText.isEmpty ? loaded : loaded.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
        .overlay { hubListStatus }
        .navigationTitle("Data Exchange Viewer")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    downloadedModelsSection
                    signInSection
                    Button("Logout") { auth.logout() }
                } label: {
                    Label("Account and Storage", systemImage: "person.crop.circle")
                }
            }
        }
        .task { await cache.loadIndexIfNeeded() }
        .task(id: hubListRetryToken) {
            hubs = .loading
            do {
                let token = try await auth.validAccessToken()
                hubs = .loaded(try await DataExchangeAPI().hubs(token: token))
            } catch {
                auth.signOutIfSessionExpired(error)
                hubs = .failed(error.userFacingDescription)
            }
        }
    }

    @ViewBuilder
    private var downloadedModelsSection: some View {
        Section("Downloaded Models") {
            Text(cache.totalSize.formatted(.byteCount(style: .file)))
            Button(role: .destructive) {
                Task { await cache.clearAll() }
            } label: {
                Label("Clear Downloaded Models", systemImage: "trash")
            }
            .disabled(cache.totalSize == 0)
        }
    }

    /// Typing an Autodesk password on a head-mounted device is slow enough that reusing the
    /// browser's existing sign-in is worth offering, so the choice is the person's rather than
    /// hardcoded. Off by default; on, every sign-in starts from a blank browser session.
    @ViewBuilder
    private var signInSection: some View {
        Section("Sign-In") {
            Toggle("Private Sign-In", isOn: Binding(
                get: { auth.usesEphemeralWebSession },
                set: { auth.usesEphemeralWebSession = $0 }
            ))
        }
    }

    /// "No hubs found" is only rendered from `.loaded`, where the list really is empty. While the
    /// request is in flight the person gets a spinner instead, and a failure says so explicitly
    /// rather than being reported as an absence of hubs.
    @ViewBuilder
    private var hubListStatus: some View {
        switch hubs {
        case .loading:
            ProgressView("Loading hubs")

        case .failed(let message):
            ContentUnavailableView {
                Label("Failed to load hubs", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { hubListRetryToken = UUID() }
            }

        case .loaded(let loaded):
            if loaded.isEmpty {
                ContentUnavailableView("No hubs found", systemImage: "building.2")
            } else if filteredHubs.isEmpty {
                // Previously an unexplained blank list.
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func loadProjectsIfNeeded(hubID: String) async {
        guard projectsByHub[hubID] == nil, !loadingHubIDs.contains(hubID) else { return }
        loadingHubIDs.insert(hubID)
        hubProjectErrors[hubID] = nil
        defer { loadingHubIDs.remove(hubID) }
        do {
            let token = try await auth.validAccessToken()
            projectsByHub[hubID] = try await DataExchangeAPI().projects(token: token, hubId: hubID)
        } catch {
            // Includes the token lookup, which used to fail silently and leave the row blank.
            auth.signOutIfSessionExpired(error)
            hubProjectErrors[hubID] = error.userFacingDescription
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
