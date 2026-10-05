import Foundation

public enum TimeFormatting {
    public static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func compactCount(_ n: Int) -> String {
        switch n {
        case ..<10_000: "\(n)"
        case ..<100_000_000: String(format: "%.1f万", Double(n) / 10_000).replacingOccurrences(of: ".0万", with: "万")
        default: String(format: "%.1f亿", Double(n) / 100_000_000).replacingOccurrences(of: ".0亿", with: "亿")
        }
    }
}
