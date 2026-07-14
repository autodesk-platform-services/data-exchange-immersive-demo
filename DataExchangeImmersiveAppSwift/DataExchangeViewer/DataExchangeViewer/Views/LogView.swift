//
//  LogView.swift
//  DataExchangeViewer
//

import SwiftUI

struct LogView: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? "Waiting for logs…" : text)
                .font(.system(.body, design: .monospaced))
                .lineLimit(nil)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
