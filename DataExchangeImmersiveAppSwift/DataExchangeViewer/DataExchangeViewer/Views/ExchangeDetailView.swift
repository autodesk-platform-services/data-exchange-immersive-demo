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
        USDzPreviewView(
            fileURL: conversion.cachedUSDzURL,
            modelName: exchange.name,
            conversionState: conversion.state
        )
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
            // The log is only fetched while it is on screen. It used to be polled in full every
            // three seconds for the lifetime of this view, whether or not the sheet was open.
            .onChange(of: isShowingConversionLog) { _, isShowing in
                conversion.setLogVisible(isShowing, auth: auth)
            }
            .task(id: exchange.id) {
                await conversion.start(auth: auth)
            }
            // The store's polling loops are unstructured tasks, so leaving this view has to
            // cancel them explicitly or they keep hitting the service with nothing observing.
            .onDisappear {
                conversion.stop()
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
        // The failure message itself is shown in the preview area, so the toolbar only needs
        // to offer the recovery action.
        case .failed:
            Button("Retry") { Task { await conversion.convert(auth: auth) } }
        }
    }
}
