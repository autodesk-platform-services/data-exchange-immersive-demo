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

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveModelView()
                .environment(appModel)
                .onAppear { appModel.immersiveSpaceState = .open }
                .onDisappear { appModel.immersiveSpaceState = .closed }
        }
        .immersionStyle(
            selection: Binding(get: { appModel.immersionKind.style }, set: { _ in }),
            in: .mixed, .full
        )
    }
}
