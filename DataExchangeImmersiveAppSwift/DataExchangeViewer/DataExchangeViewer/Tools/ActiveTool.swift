//
//  ActiveTool.swift
//  DataExchangeViewer
//

import Foundation

/// Which of Volume mode's tools currently owns the model's transforms.
///
/// Mutually exclusive by construction, because all three candidates — the section box, explode, and
/// the standard `ManipulationComponent` move/rotate/scale — want to write the same transforms. Two
/// of them active at once doesn't produce a compromise, it produces a fight per frame.
enum ActiveTool: String, CaseIterable, Identifiable, Sendable {
    case none
    case section
    case explode

    var id: Self { self }

    /// The two the toolbar offers. `none` is a state, not a button.
    static var selectable: [ActiveTool] { [.section, .explode] }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .section: String(localized: "Section")
        case .explode: String(localized: "Explode")
        }
    }

    var symbol: String {
        switch self {
        case .none: "hand.point.up.left"
        case .section: "cube.transparent"
        case .explode: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    var hint: String {
        switch self {
        case .none:
            String(localized: "Pinch and drag to move the model; use two hands to rotate or resize")
        case .section:
            String(localized: "Cuts the model with a box you can drag by its faces")
        case .explode:
            String(localized: "Drag to separate the model's parts along its longest axis")
        }
    }
}
