//
//  PreviewMode.swift
//  DataExchangeViewer
//

import Foundation

/// The three ways the app presents a converted model, each backed by a different scene type.
///
/// Raw values are persisted and must stay stable; `PreviewModeDefaults.migrate` maps superseded
/// values forward, so nothing here needs to know about them.
///
/// The person-facing strings live here rather than in the picker so that the name of a mode, its
/// hint, and its symbol are defined once, and a rename cannot leave a stale one behind in an
/// accessibility hint nobody reads until VoiceOver reads it.
enum PreviewMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// A portal inside the app's own plain window. The default: no passthrough replaced, no volume
    /// claimed, nothing to dismiss — the mode for glancing at a model while reading the file list.
    case portal
    /// A volumetric window the person positions and resizes, with the section and explode tools.
    case volume
    /// A `.full` immersive space at 1:1 scale, with locomotion controls.
    case immersive

    var id: Self { self }

    /// Exactly one mode is active at a time, and only Portal can be shown before a conversion
    /// finishes — the other two need a USDZ on disk.
    var requiresModel: Bool { self != .portal }

    var title: String {
        switch self {
        case .portal: String(localized: "Portal")
        case .volume: String(localized: "Volume")
        case .immersive: String(localized: "Immersive")
        }
    }

    var symbol: String {
        switch self {
        case .portal: "rectangle.portrait.on.rectangle.portrait.angled"
        case .volume: "cube.transparent"
        case .immersive: "figure.walk"
        }
    }

    var hint: String {
        switch self {
        case .portal:
            String(localized: "Shows the model through a portal in this window")
        case .volume:
            String(localized: "Opens a volume you can place and resize, with section and explode tools")
        case .immersive:
            String(localized: "Replaces your surroundings with the model at full size, with controls for moving through it")
        }
    }
}
