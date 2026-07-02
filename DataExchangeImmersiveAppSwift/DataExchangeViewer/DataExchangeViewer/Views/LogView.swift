//
//  LogView.swift
//  DataExchangeViewer
//

import SwiftUI

struct LogView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Waiting for logs…" : text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
