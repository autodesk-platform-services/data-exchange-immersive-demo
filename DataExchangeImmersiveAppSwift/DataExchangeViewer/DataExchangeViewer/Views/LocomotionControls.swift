//
//  LocomotionControls.swift
//  DataExchangeViewer
//

import SwiftUI
import simd

/// The controls that move someone through a model at 1:1: a fly puck, an altitude slider, and
/// recentre.
///
/// Presented as a SwiftUI attachment that follows the wearer's gaze with a soft lag (see
/// `ImmersiveModelView`), so it stays within reach without being pinned to the middle of the view.
struct LocomotionControls: View {
    @Bindable var locomotion: LocomotionController
    /// The vertical range the altitude slider spans, in meters, derived from the model's own height.
    let altitudeRange: ClosedRange<Float>
    /// Shown when the device is thermally constrained, so reduced detail reads as the device
    /// managing itself rather than as a broken model.
    let thermalNotice: String?

    var body: some View {
        VStack(spacing: 12) {
            if let thermalNotice {
                Label(thermalNotice, systemImage: "thermometer.medium")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 20) {
                FlyPuck(stick: $locomotion.stick) { forward in
                    locomotion.step(forward: forward)
                }
                .frame(width: 132, height: 132)

                VStack(spacing: 6) {
                    Image(systemName: "arrow.up.and.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $locomotion.altitude,
                        in: altitudeRange
                    ) {
                        Text("Altitude")
                    }
                    .frame(height: 132)
                    // A vertical slider is the natural mapping for vertical travel, and SwiftUI
                    // has no vertical slider style — rotating the horizontal one is the standard
                    // workaround, and the accessibility label below keeps it comprehensible.
                    .rotationEffect(.degrees(-90))
                    .frame(width: 44, height: 132)
                    .accessibilityLabel("Altitude")
                    .accessibilityValue("\(Int(locomotion.altitude.rounded())) meters above the entry point")
                }

                VStack(spacing: 10) {
                    Button {
                        locomotion.recentre()
                    } label: {
                        Label("Recentre", systemImage: "scope")
                            .labelStyle(.iconOnly)
                            .font(.title2)
                    }
                    .accessibilityHint("Returns you to where you started, at the model's entry point")

                    Text(distanceLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(Int(locomotion.distanceFromEntry.rounded())) meters from the entry point")
                }
            }

            Picker("Speed", selection: $locomotion.speed) {
                ForEach(LocomotionController.Speed.allCases) { speed in
                    Text(speed.title).tag(speed)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .accessibilityLabel("Travel speed")
        }
        .padding(16)
        .glassBackgroundEffect()
    }

    private var distanceLabel: String {
        let metres = locomotion.distanceFromEntry
        return metres < 1 ? "0 m" : "\(Int(metres.rounded())) m"
    }
}

/// A thumbstick-style pad. Drag from anywhere inside it; the knob follows and the offset from the
/// centre becomes horizontal velocity in the direction of gaze.
///
/// A pad rather than four directional buttons: holding a button flies at a fixed speed in a fixed
/// direction, so following a corridor means a sequence of discrete holds, while a puck gives a
/// continuous heading — which is what walking through a building actually needs.
private struct FlyPuck: View {
    @Binding var stick: SIMD2<Float>
    /// A discrete step, for input that can't drag. 1 is forward, −1 back.
    let onStep: (Float) -> Void
    @State private var isDragging = false

    /// Radius the knob can travel, as a fraction of the pad. Leaves the knob visibly inside the
    /// pad at full deflection rather than half-off its edge.
    private static let travelFraction: CGFloat = 0.34

    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) * Self.travelFraction
            ZStack {
                Circle()
                    .fill(.thinMaterial)
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 1)
                Image(systemName: "move.3d")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(isDragging ? 0 : 0.7)
                Circle()
                    .fill(.white.opacity(isDragging ? 0.9 : 0.55))
                    .frame(width: 34, height: 34)
                    .offset(
                        x: CGFloat(stick.x) * radius,
                        y: CGFloat(stick.y) * radius
                    )
            }
            .contentShape(Circle())
            .hoverEffect()
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        stick = SIMD2<Float>(
                            Float(value.translation.width / radius),
                            Float(value.translation.height / radius)
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
                        // Releasing stops travel. A puck that kept its last value would leave
                        // someone drifting through a wall after they let go.
                        stick = .zero
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Fly")
        .accessibilityHint("Drag to move horizontally in the direction you are facing")
        // VoiceOver and Full Keyboard Access can't drag, so the pad is also adjustable: each
        // increment is one step forward, each decrement one step back. A discrete step rather than
        // a deflection of the stick, which nothing would then release — leaving someone travelling
        // indefinitely with no way to stop.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onStep(1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }
}
