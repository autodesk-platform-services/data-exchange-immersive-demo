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
    // Pin the sidebar open. With the default `.automatic` visibility the split view can launch
    // collapsed to detail-only (e.g. via state restoration), leaving just the "Select a project"
    // placeholder in a tiny window with no way to reach the sidebar.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedProject: $selectedProject)
                .navigationSplitViewColumnWidth(min: 320, ideal: 360)
        } detail: {
            if let selectedProject {
                ExchangeListView(project: selectedProject)
                    .id(selectedProject.id)
            } else {
                ContentUnavailableView("Select a project", systemImage: "folder")
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
