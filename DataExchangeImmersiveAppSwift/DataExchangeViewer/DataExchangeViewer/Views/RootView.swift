//
//  RootView.swift
//  DataExchangeViewer
//

import SwiftUI

struct RootView: View {
    @Environment(AuthManager.self) private var auth
    @State private var bootstrapped = false

    var body: some View {
        Group {
            if !bootstrapped {
                ProgressView()
            } else if auth.isAuthenticated {
                MainSplitView()
            } else {
                LoginView()
            }
        }
        .task {
            await auth.bootstrap()
            bootstrapped = true
        }
    }
}

struct MainSplitView: View {
    @State private var selectedProject: Project?

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedProject: $selectedProject)
        } detail: {
            if let selectedProject {
                ExchangeListView(project: selectedProject)
                    .id(selectedProject.id)
            } else {
                ContentUnavailableView("Select a project", systemImage: "folder")
            }
        }
    }
}
