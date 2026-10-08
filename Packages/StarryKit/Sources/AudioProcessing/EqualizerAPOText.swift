import Foundation

/// Equalizer APO's configuration text (what AutoEQ's `ParametricEQ.txt` and Room EQ Wizard's
/// filter settings are written in): `Preamp:` and `Filter:` lines, read the way Equalizer APO
/// 1.4 reads them so that a file sounds the same here.
public enum EqualizerAPOText {
    public struct Profile: Sendable, Equatable {
        /// dB, the sum of the `Preamp:` lines.
        public var preamp: Double = 0
        /// In file order, in slots 0, 1, 2…
        public var bands: [ParametricBand] = []
        /// Filters past `ParametricEqualizer.maxBands`, left out.
        public var droppedFilters = 0
        /// Equalizer APO commands that shape the sound and are not done here (channel
        /// selection, graphic EQ, convolution…), each once in file order.
        public var skippedCommands: [String] = []

        public init() {}
    }

    /// Commands that change what Equalizer APO plays; any other line is a comment or a header.
    static let unsupportedCommands: Set<String> = [
        "Channel", "Copy", "Delay", "GraphicEQ", "Convolution", "Include", "Device", "Stage",
        "If", "ElseIf", "Else", "EndIf", "Eval", "VSTPlugin", "LoudnessCorrection",
    ]

    public static func parse(_ text: String) -> Profile {
        var profile = Profile()
        let patterns = Patterns()
        // A byte order mark (Notepad's "UTF-8 with BOM") would hide the first command.
        for rawLine in text.replacingOccurrences(of: "\u{FEFF}", with: "").split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let command = line[..<colon].trimmingCharacters(in: .whitespaces)
            let parameters = String(line[line.index(after: colon)...])
            if command == "Preamp" {
                let value = parameters.replacingOccurrences(of: ",", with: ".")
                if let gain = patterns.first(patterns.preamp, in: value).flatMap(Double.init), gain.isFinite { profile.preamp += gain }
            } else if command.hasPrefix("Filter") {
                guard var band = filter(parameters, patterns: patterns) else { continue }
                guard profile.bands.count < ParametricEqualizer.maxBands else {
                    profile.droppedFilters += 1
                    continue
                }
                band.slot = profile.bands.count
                profile.bands.append(band)
            } else if unsupportedCommands.contains(command), !profile.skippedCommands.contains(command) {
                profile.skippedCommands.append(command)
            }
        }
        return profile
    }

    /// The bands (by frequency) after the preamp, a band that is off as an `OFF` line.
    public static func text(preamp: Double, bands: [ParametricBand]) -> String {
        var lines = ["Preamp: \(ParametricEqualizer.trimmed(preamp, decimals: 2)) dB"]
        for (index, band) in bands.sorted(by: { $0.frequency < $1.frequency }).enumerated() {
            var line = "Filter \(index + 1): \(band.isOn ? "ON" : "OFF") \(typeName(band.filter)) Fc \(ParametricEqualizer.trimmed(band.frequency, decimals: 1)) Hz"
            if band.filter.hasGain { line += " Gain \(ParametricEqualizer.trimmed(band.gain, decimals: 2)) dB" }
            line += " Q \(ParametricEqualizer.qText(band.q))"
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func typeName(_ filter: ParametricFilter) -> String {
        switch filter {
        case .peak: "PK"
        case .lowShelf: "LSC"
        case .highShelf: "HSC"
        case .lowPass: "LPQ"
        case .highPass: "HPQ"
        case .bandPass: "BP"
        case .notch: "NO"
        case .allPass: "AP"
        }
    }

    static let types: [String: ParametricFilter] = [
        "PK": .peak, "PEQ": .peak, "Modal": .peak,
        "LP": .lowPass, "LPQ": .lowPass, "HP": .highPass, "HPQ": .highPass, "BP": .bandPass,
        "LS": .lowShelf, "LSC": .lowShelf, "HS": .highShelf, "HSC": .highShelf,
        "NO": .notch, "AP": .allPass,
    ]

    private struct Patterns {
        let preamp = regex(#"^\s*([-+0-9.eE]+)\s*dB"#)
        let type = regex(#"^\s*(ON|OFF)\s+([A-Za-z]+)"#)
        let frequency = regex("\\s+Fc\\s*([-+0-9.eE\u{00A0}]+)\\s*H\\s*z")
        let gain = regex(#"\s+Gain\s*([-+0-9.eE]+)\s*dB"#)
        let q = regex(#"\s+Q\s*([-+0-9.eE]+)"#)
        let bandwidth = regex(#"\s+BW\s+Oct\s*([-+0-9.eE]+)"#)
        let slope = regex(#"^\s*([-+0-9.eE]+)\s*dB"#)

        static func regex(_ pattern: String) -> NSRegularExpression {
            // The patterns are fixed: a failure is a programming error.
            try! NSRegularExpression(pattern: pattern)
        }

        /// The last group of the first match.
        func first(_ regex: NSRegularExpression, in text: String) -> String? {
            groups(regex, in: text)?.last
        }

        func groups(_ regex: NSRegularExpression, in text: String) -> [String]? {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }

        func suffix(after regex: NSRegularExpression, in text: String) -> String {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range), let end = Range(match.range, in: text)?.upperBound else { return text }
            return String(text[end...])
        }
    }

    /// One `Filter:` line's band (slot 0), nil when Equalizer APO would not add it either.
    private static func filter(_ text: String, patterns: Patterns) -> ParametricBand? {
        // A decimal comma, as Equalizer APO accepts.
        let text = text.replacingOccurrences(of: ",", with: ".")
        guard let head = patterns.groups(patterns.type, in: text), head.count == 2, let type = types[head[1]] else { return nil }
        let isOn = head[0] == "ON"
        let parameters = patterns.suffix(after: patterns.type, in: text)
        guard let frequency = patterns.first(patterns.frequency, in: parameters).flatMap(Self.frequency), frequency > 0 else { return nil }

        var gain = 0.0
        if type.hasGain {
            guard let value = patterns.first(patterns.gain, in: parameters).flatMap(Double.init) else { return nil }
            gain = value
        }
        var width = 0.0
        var isBandwidthOrSlope = false
        if let q = patterns.first(patterns.q, in: parameters).flatMap(Double.init) { width = q }
        if type != .lowShelf, type != .highShelf, let octaves = patterns.first(patterns.bandwidth, in: parameters).flatMap(Double.init) {
            width = octaves
            isBandwidthOrSlope = true
        }
        if type == .lowShelf || type == .highShelf, let slope = patterns.first(patterns.slope, in: parameters).flatMap(Double.init) {
            width = slope
            isBandwidthOrSlope = true
        }

        var isCornerFrequency = false
        if width == 0 {
            switch type {
            case .peak, .allPass: return nil
            case .lowPass, .highPass, .bandPass: width = 1 / 2.0.squareRoot()
            case .lowShelf, .highShelf:
                width = 0.9 // Equalizer APO's slope then, matched to Room EQ Wizard
                isBandwidthOrSlope = true
            case .notch: width = 30
            }
        } else if type == .lowShelf || type == .highShelf {
            // A slope is in dB per octave; 12 dB is the steepest a shelf keeps without overshoot.
            if isBandwidthOrSlope { width /= 12 }
            isCornerFrequency = !head[1].hasSuffix("C")
        }
        guard width.isFinite, width > 0 else { return nil }

        var centre = frequency
        let q: Double
        if type == .lowShelf || type == .highShelf {
            let a = pow(10, gain / 40)
            let slope = isBandwidthOrSlope ? min(width, 1) : 1 / ((1 / (width * width) - 2) / (a + 1 / a) + 1)
            q = isBandwidthOrSlope ? 1 / ((a + 1 / a) * (1 / slope - 1) + 2).squareRoot() : width
            if isCornerFrequency, slope > 0 {
                // A corner frequency as the Behringer DCX2496 has it: the centre is further in.
                let factor = pow(10, abs(gain) / 80 / slope)
                centre = type == .lowShelf ? frequency * factor : frequency / factor
            }
        } else if isBandwidthOrSlope {
            // Equalizer APO's bandwidth takes the digital frequency warping into account; at the
            // 48 kHz reference this is the same filter, and close at other rates.
            let w0 = min(2 * Double.pi * frequency / EqualizerResponse.referenceRate, Double.pi * 0.98)
            q = 1 / (2 * sinh(log(2) / 2 * width * w0 / sin(w0)))
        } else {
            q = width
        }
        guard q.isFinite, q > 0, centre.isFinite else { return nil }
        return ParametricBand(slot: 0, filter: type, frequency: centre, gain: gain, q: q, isOn: isOn).clamped
    }

    /// Hz as Equalizer APO reads it: a non-breaking space is a thousands separator, and so is
    /// a point followed by exactly three digits ("1.000" from Room EQ Wizard is 1000 Hz).
    static func frequency(_ text: String) -> Double? {
        let text = text.replacingOccurrences(of: "\u{00A0}", with: "")
        let number = text.prefix { "0123456789.+-eE".contains($0) }
        guard var value = Double(number) else { return nil }
        if number.count >= 5, !number.contains(where: { $0 == "e" || $0 == "E" }) {
            let point = number.index(number.endIndex, offsetBy: -4)
            if number[point] == "." { value *= 1000 }
        }
        return value
    }
}
