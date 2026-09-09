//
//  ActiveTool.swift
//  DataExchangeViewer
//

import Foundation

/// The mutually exclusive tools available in Volume preview.
enum ActiveTool: String, CaseIterable, Identifiable, Sendable {
    case none
    case plane
    case section
    case measure
    case explode

    var id: Self { self }

    /// The tools the toolbar offers. `none` is a state, not a button.
    static var selectable: [ActiveTool] { [.plane, .section, .explode, .measure] }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .plane: String(localized: "Plane clipping")
        case .section: String(localized: "Box clipping")
        case .measure: String(localized: "Measure")
        case .explode: String(localized: "Explode")
        }
    }

    var symbol: String {
        switch self {
        case .none: "hand.point.up.left"
        case .plane: "rectangle.split.2x1"
        case .section: "cube.transparent"
        case .measure: "ruler"
        case .explode: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    var hint: String {
        switch self {
        case .none:
            String(localized: "Pinch and drag to move the model; use two hands to rotate or resize")
        case .plane:
            String(localized: "Choose an axis, then pinch and drag the plane to cut the model")
        case .measure:
            String(localized: "Pinch two points on the design to measure their distance")
        case .section:
            String(localized: "Cuts the model with a box you can drag by its faces")
        case .explode:
            String(localized: "Drag to separate the model's parts along the selected X, Y, or Z axis")
        }
    }
}
