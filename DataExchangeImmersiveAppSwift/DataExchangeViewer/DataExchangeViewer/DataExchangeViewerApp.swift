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
    /// One loaded model, shared by all three scenes. Held at app level rather than per scene
    /// because that is the whole point of it: an entity has a single parent, so the model is loaded
    /// once and re-parented as the mode changes.
    @State private var modelStore = ModelStore()

    var body: some Scene {
        // Portal mode lives in the app's own plain window, alongside the exchange list — no volume
        // claimed, no passthrough replaced, nothing to dismiss.
        WindowGroup {
            RootView()
                .environment(authManager)
                .environment(appModel)
                .environment(modelStore)
        }
        .defaultSize(width: 1280, height: 800)

        // Volume mode. Positioned and resized by the person, never programmatically; the app only
        // fits the model to whatever bounds it currently has.
        WindowGroup(id: appModel.volumeWindowID) {
            VolumeView()
                .environment(appModel)
                .environment(modelStore)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.0, height: 1.0, depth: 1.0, in: .meters)

        // Immersive mode. `.full` only: a 1:1 walkthrough with the room still showing through gave
        // two conflicting senses of where the floor was.
        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveModelView()
                .environment(appModel)
                .environment(modelStore)
        }
        .immersionStyle(selection: $appModel.immersionStyle, in: .full)
    }
}
