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

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveModelView()
                .environment(appModel)
        }
        .immersionStyle(selection: $appModel.immersionStyle, in: .mixed, .progressive, .full)
    }
}
