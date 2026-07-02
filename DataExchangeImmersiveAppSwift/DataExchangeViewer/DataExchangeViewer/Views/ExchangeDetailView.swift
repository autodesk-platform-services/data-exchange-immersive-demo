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
        TabView {
            USDzPreviewView(fileURL: conversion.cachedUSDzURL)
                .tabItem { Label("Preview", systemImage: "cube.transparent") }
            LogView(text: conversion.logText)
                .tabItem { Label("Log", systemImage: "doc.plaintext") }
        }
        .navigationTitle(exchange.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                convertClearControl
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
            Button("Clear", role: .destructive) { Task { await conversion.clear(auth: auth) } }
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
