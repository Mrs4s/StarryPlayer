import Foundation

/// An opaque sRGB colour, written `#RRGGBB` (TTML `ttv:color`).
public struct LyricColor: Sendable, Hashable, Codable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init?(hex: String) {
        let text = hex.trimmingCharacters(in: .whitespaces)
        let digits = text.dropFirst()
        guard text.first == "#", digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    public var description: String { hex }

    public static let performerPalette: [LyricColor] = [
        "#D9695B", "#4C6FD1", "#3F9A66", "#C98A1E", "#8462CC", "#2F93A3", "#C2558D", "#7D8A35",
    ].map { LyricColor(hex: $0)! }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let color = LyricColor(hex: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected #RRGGBB")
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
