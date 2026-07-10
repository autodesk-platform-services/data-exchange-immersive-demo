//
//  ExchangeDetailView.swift
//  DataExchangeViewer
//

import SwiftUI

struct ExchangeDetailView: View {
    let exchange: Exchange
    @Environment(AuthManager.self) private var auth
    @State private var conversion: ConversionStore

    init(exchange: Exchange) {
        self.exchange = exchange
        _conversion = State(initialValue: ConversionStore(exchange: exchange))
    }

    var body: some View {
        // Preview/Logs used to be separate TabView tabs; both are now segments of the mode
        // picker inside USDzPreviewView's ornament, so this is the view's only content.
        USDzPreviewView(fileURL: conversion.cachedUSDzURL, modelName: exchange.name, logText: conversion.logText)
            .navigationTitle(exchange.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        convertClearControl
                        QuickLookButton(fileURL: conversion.cachedUSDzURL)
                    }
                }
            }
            .task(id: exchange.id) {
                await conversion.start(auth: auth)
            }
    }

    @ViewBuilder
    private var convertClearControl: some View {
        switch conversion.state {
        case .checking:
            ProgressView()
        case .notConverted:
            Button("Convert") { Task { await conversion.convert(auth: auth) } }
        case .running:
            Label("Converting…", systemImage: "hourglass")
                .labelStyle(.titleAndIcon)
        case .completed:
            Button(role: .destructive) { Task { await conversion.clear(auth: auth) } } label: {
                Label("Clear", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 2) {
                Button("Retry") { Task { await conversion.convert(auth: auth) } }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
