//
//  QuickLookButton.swift
//  DataExchangeViewer
//

import SwiftUI
import QuickLook

/// Opens the model in the system's built-in Quick Look AR viewer — a fully platform-native way
/// to preview and export a USDZ, independent of (and able to run alongside) the app's own preview
/// modes. Quick Look's own share sheet is how the user actually saves/downloads the file.
struct QuickLookButton: View {
    let fileURL: URL?

    var body: some View {
        Button {
            guard let fileURL else { return }
            _ = PreviewApplication.open(urls: [fileURL])
        } label: {
            Label("Download", systemImage: "square.and.arrow.down")
        }
        // Icon-only, matching Clear's circular toolbar icon button — "Download" stays the
        // accessible label even though the text isn't shown.
        .labelStyle(.iconOnly)
        .accessibilityHint("Opens the model in the system AR viewer, where it can be saved")
        .disabled(fileURL == nil)
    }
}
