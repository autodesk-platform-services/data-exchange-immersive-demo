import simd

/// Axes are expressed in the model's metric frame, regardless of its presentation scale.
enum ToolAxis: String, CaseIterable, Identifiable, Sendable {
    case x = "X", y = "Y", z = "Z"
    var id: Self { self }
    var index: Int { Self.allCases.firstIndex(of: self)! }
    var direction: SIMD3<Float> {
        var vector = SIMD3<Float>.zero
        vector[index] = 1
        return vector
    }
}
