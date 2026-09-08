//
//  ThermalQuality.swift
//  DataExchangeViewer
//

import Foundation
import SwiftUI
import RealityKit

/// Watches the device's thermal state and reports when rendering should back off.
///
/// An architectural model at 1:1 in a full immersive space is the heaviest thing this app does, and
/// the failure mode is not a crash — it is the compositor missing frames, which on a headset is
/// felt rather than seen. By the time frame rate visibly degrades the device has already been
/// throttling for a while, so quality is dropped on the thermal signal instead: coarser LOD
/// switching distances and cheaper shadows, before rather than after.
@MainActor
@Observable
final class ThermalQuality {
    private(set) var state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    /// `.serious` and `.critical` are the two states where the system is already reducing
    /// performance to shed heat, so they are the two where the app should stop asking for as much.
    var isConstrained: Bool {
        state == .serious || state == .critical
    }

    /// A message worth showing the person, or nil while there is nothing to say. Someone whose
    /// model has just become visibly coarser deserves to know it was the device and not the export.
    var notice: String? {
        switch state {
        case .serious:
            String(localized: "The device is warm, so detail has been reduced to hold the frame rate.")
        case .critical:
            String(localized: "The device is very warm. Detail is at its lowest; consider taking a break.")
        default:
            nil
        }
    }

    /// Held outside observation and outside the actor: `deinit` is not main-actor isolated, and
    /// removing the observer there is the only place this is read after `init` writes it once.
    @ObservationIgnored
    private nonisolated(unsafe) var observation: NSObjectProtocol?

    init() {
        observation = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification carries no payload; the current state is read from ProcessInfo.
            // `.main` queue plus a main-actor hop, because the observation itself makes no
            // guarantee beyond the queue.
            MainActor.assumeIsolated {
                self?.state = ProcessInfo.processInfo.thermalState
            }
        }
    }

    deinit {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    /// Shadow quality follows the same signal. Dropping to a cheaper shadow before the frame rate
    /// goes is the least noticeable of the available savings on a model made mostly of flat slabs.
    func applyShadowQuality(to entity: Entity?) {
        guard let entity else { return }
        var component = entity.components[DynamicLightShadowComponent.self]
            ?? DynamicLightShadowComponent(castsShadow: true)
        component.castsShadow = !isConstrained
        entity.components.set(component)
    }
}
