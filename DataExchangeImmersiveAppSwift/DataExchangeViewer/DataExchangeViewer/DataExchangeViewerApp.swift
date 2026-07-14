//
//  DataExchangeViewerApp.swift
//  DataExchangeViewer
//
//  Created by Petr Broz on 02.07.2026.
//

import SwiftUI

@main
struct DataExchangeViewerApp: App {
    @State private var authManager = AuthManager()
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authManager)
                .environment(appModel)
        }
        .defaultSize(width: 1280, height: 800)

        WindowGroup(id: appModel.volumetricWindowID, for: URL.self) { fileURLBinding in
            VolumetricModelView(fileURL: fileURLBinding.wrappedValue)
                .environment(appModel)
                .onAppear { appModel.isVolumetricWindowOpen = true }
                .onDisappear { appModel.isVolumetricWindowOpen = false }
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.6, height: 0.6, depth: 0.6, in: .meters)
        // Without an explicit placement, the system may spawn this window somewhere outside the
        // user's current view. Anchoring it beside the main window guarantees it opens in view.
        .defaultWindowPlacement { _, context in
            if let mainWindow = context.windows.first {
                WindowPlacement(.trailing(mainWindow))
            } else {
                WindowPlacement()
            }
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveModelView()
                .environment(appModel)
                .onAppear { appModel.immersiveSpaceState = .open }
                .onDisappear { appModel.immersiveSpaceState = .closed }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
