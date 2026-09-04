//
//  ExchangeDetailView.swift
//  DataExchangeViewer
//

import SwiftUI

struct ExchangeDetailView: View {
    let exchange: Exchange
    @Environment(AuthManager.self) private var auth
    @State private var conversion: ConversionStore
    @State private var isShowingConversionLog = false

    init(exchange: Exchange) {
        self.exchange = exchange
        _conversion = State(initialValue: ConversionStore(exchange: exchange))
    }

    var body: some View {
        USDzPreviewView(fileURL: conversion.cachedUSDzURL, modelName: exchange.name)
            .navigationTitle(exchange.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        convertClearControl
                        QuickLookButton(fileURL: conversion.cachedUSDzURL)
                        Menu {
                            Button {
                                isShowingConversionLog = true
                            } label: {
                                Label("Conversion Log", systemImage: "doc.plaintext")
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingConversionLog) {
                NavigationStack {
                    LogView(text: conversion.logText)
                        .navigationTitle("Conversion Log")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isShowingConversionLog = false }
                            }
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
