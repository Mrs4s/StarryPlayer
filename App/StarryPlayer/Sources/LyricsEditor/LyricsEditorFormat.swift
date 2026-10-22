import AudioProcessing
import Foundation

enum LyricsEditorFormat {
    static func time(_ time: TimeInterval?, digits: Int = 2) -> String {
        guard let time else { return "--:--" }
        let scale = digits == 3 ? 1000.0 : 100.0
        let units = Int((max(time, 0) * scale).rounded())
        let whole = units / Int(scale)
        let fraction = units % Int(scale)
        return String(format: digits == 3 ? "%02d:%02d.%03d" : "%02d:%02d.%02d", whole / 60, whole % 60, fraction)
    }

    static func lead(_ lead: TimeInterval) -> String {
        lead == 0 ? "不补偿" : "提前 \(Int((lead * 1000).rounded())) 毫秒"
    }

    static func gain(_ gain: Double) -> String {
        let text = rate(gain)
        return abs(gain - Double(Spectrogram.defaultGain)) < 0.001 ? "\(text)（默认）" : text
    }

    static func rate(_ rate: Double) -> String {
        let text = String(format: "%.2f", rate).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return "\(text)×"
    }

    /// Seconds from `83.4`, `1:23.4` or `01:23.400`; nil when it is none of these.
    static func seconds(from text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "：", with: ":").split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
