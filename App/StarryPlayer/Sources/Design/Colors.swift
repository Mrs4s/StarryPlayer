import AppKit
import SwiftUI

extension Color {
    static func rgb(_ r: Double, _ g: Double, _ b: Double, alpha: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: alpha)
    }

    static func hsb(_ hue: Double, _ saturation: Double, _ brightness: Double, alpha: Double = 1) -> Color {
        Color(hue: hue.truncatingRemainder(dividingBy: 1), saturation: min(max(saturation, 0), 1), brightness: min(max(brightness, 0), 1), opacity: alpha)
    }

    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        var int: UInt64 = 0
        Scanner(string: value).scanHexInt64(&int)
        let r, g, b: UInt64
        switch value.count {
        case 6: (r, g, b) = (int >> 16, (int >> 8) & 0xFF, int & 0xFF)
        default: (r, g, b) = (0xFE, 0x79, 0x71)
        }
        self = .rgb(Double(r), Double(g), Double(b))
    }

    var hsb: (hue: Double, saturation: Double, brightness: Double)? {
        guard let ns = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }

    /// Relative luminance: 0 = black, 1 = white.
    var luminance: Double {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return 0 }
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(ns.redComponent) + 0.7152 * linear(ns.greenComponent) + 0.0722 * linear(ns.blueComponent)
    }

    var lightTint: Color {
        guard let hsb else { return .white }
        return .hsb(hsb.hue, min(hsb.saturation, 0.35) * 0.6, 0.94)
    }
}

enum PlaceholderArt {
    static func hue(for seed: String) -> Double {
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Double(hash % 360) / 360
    }

    static func colors(for seed: String) -> [Color] {
        let h = hue(for: seed)
        return [.hsb(h, 0.55, 0.62), .hsb(h + 0.08, 0.6, 0.38), .hsb(h - 0.06, 0.45, 0.22)]
    }

    static func accent(for seed: String) -> Color {
        .hsb(hue(for: seed), 0.6, 0.75)
    }
}

extension Date {
    var ymd: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }

    /// Year-only dates are represented as January 1 at 00:00 UTC.
    var isYearOnly: Bool {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let c = utc.dateComponents([.month, .day, .hour, .minute, .second], from: self)
        return c.month == 1 && c.day == 1 && c.hour == 0 && c.minute == 0 && c.second == 0
    }

    var utcYear: Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        return utc.component(.year, from: self)
    }
}
