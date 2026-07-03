//
//  RootView.swift
//  DataExchangeViewer
//

import SwiftUI

struct RootView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
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
        // The immersive space is a separate scene from this window, so closing the window
        // doesn't dismiss it on its own — without this, the model stays visible after the
        // user closes the app's only window.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background, appModel.immersiveSpaceState != .closed else { return }
            Task { await dismissImmersiveSpace() }
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
