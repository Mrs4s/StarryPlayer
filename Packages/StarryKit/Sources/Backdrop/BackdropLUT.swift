import simd

/// LUT axes: x = red, y = green, slice = blue.
@MainActor
public enum BackdropLUT {
    public static nonisolated let size = 32

    /// The table to grade with; set before the first backdrop is made. nil: `BackdropGrade`.
    public static var table: [UInt8]?

    public nonisolated static func lookup(_ c: SIMD3<Float>, in table: [UInt8]) -> SIMD3<Float> {
        let i = simd_clamp(SIMD3<Int>((c * Float(size - 1)).rounded(.toNearestOrEven)), SIMD3(repeating: 0), SIMD3(repeating: size - 1))
        let o = ((i.z * size + i.y) * size + i.x) * 4
        return SIMD3(Float(table[o]), Float(table[o + 1]), Float(table[o + 2])) / 255
    }
}
