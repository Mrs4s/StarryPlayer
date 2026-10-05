import Foundation
import LyricsCore

public enum LyricsPin: Sendable, Hashable {
    case source(LyricsCandidateSource)
    case song(LyricsSearchResult)
    case file(LyricsFile)
}

/// A lyric file opened by hand, kept with its text so the song keeps its lyrics when the file
/// moves or goes.
public struct LyricsFile: Sendable, Codable, Hashable {
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    /// Reads a lyric file: UTF-8 or UTF-16 text, GB 18030 for older Chinese LRC files, and
    /// an encrypted `.krc`. nil when it is none of these or holds nothing.
    public init?(name: String, data: Data) {
        guard let text = Self.text(from: data), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(name: name, text: text)
    }

    public static let extensions = ["lrc", "ttml", "yrc", "qrc", "krc", "xml", "txt"]

    /// The format the extension names; nil leaves it to detection (.txt, .xml).
    var declaredFormat: LyricsDocument.Format? {
        LyricsDocument.Format(rawValue: (name as NSString).pathExtension.lowercased())
    }

    static func text(from data: Data) -> String? {
        if KRCCipher.isKRC(data) { return try? KRCCipher.text(from: data) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb18030))
    }
}

enum KRCCipher {
    enum Failure: Error { case notKRC }

    private static let key: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69]

    static func isKRC(_ data: Data) -> Bool {
        data.count > 4 && data.prefix(4) == Data("krc1".utf8)
    }

    static func text(from data: Data) throws -> String {
        guard isKRC(data) else { throw Failure.notKRC }
        let scrambled = Array(data.dropFirst(4))
        let deflated = scrambled.enumerated().map { $0.element ^ key[$0.offset % key.count] }
        return String(decoding: try Inflate.decompress(deflated), as: UTF8.self)
    }
}

/// One provider's answer to a typed search: its songs, or nil when the search failed.
public struct LyricsSearchAnswer: Sendable {
    public var provider: LyricsProviderID
    public var results: [LyricsSearchResult]?

    public init(provider: LyricsProviderID, results: [LyricsSearchResult]?) {
        self.provider = provider
        self.results = results
    }
}
