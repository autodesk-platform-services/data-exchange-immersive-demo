//
//  QuickLookButton.swift
//  DataExchangeViewer
//

import SwiftUI
import QuickLook

/// Opens the model in the system's built-in Quick Look AR viewer — a fully platform-native way
/// to preview a USDZ, independent of (and able to run alongside) the app's own preview modes.
struct QuickLookButton: View {
    let fileURL: URL?

    var body: some View {
        Button {
            guard let fileURL else { return }
            _ = PreviewApplication.open(urls: [fileURL])
        } label: {
            Label("Quick Look", systemImage: "arkit")
        }
        .disabled(fileURL == nil)
    }
}
