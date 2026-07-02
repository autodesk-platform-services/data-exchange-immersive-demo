//
//  HubsProjectsStore.swift
//  DataExchangeViewer
//

import Foundation

@Observable
final class HubsProjectsStore {
    private(set) var hubs: [Hub] = []
    private(set) var projectsByHub: [String: [Project]] = [:]
    private(set) var loadingHubIDs: Set<String> = []
    private(set) var errorMessage: String?

    private let api = DataExchangeAPI()

    func loadHubs(token: String) async {
        errorMessage = nil
        do {
            hubs = try await api.hubs(token: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadProjectsIfNeeded(hubID: String, token: String) async {
        guard projectsByHub[hubID] == nil, !loadingHubIDs.contains(hubID) else { return }
        loadingHubIDs.insert(hubID)
        defer { loadingHubIDs.remove(hubID) }
        do {
            projectsByHub[hubID] = try await api.projects(token: token, hubId: hubID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
