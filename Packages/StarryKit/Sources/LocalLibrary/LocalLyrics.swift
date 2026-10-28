import Foundation
import LyricsCore
import LyricsProviders
import MusicSources

enum LocalLyrics {
    static let sidecarExtensions = ["ttml", "yrc", "qrc", "krc", "krl", "ass", "ssa", "lrc", "kra", "srt", "txt"]

    static func find(for song: URL, providerName: String) async -> RawLyrics? {
        if let sidecar = sidecar(for: song, providerName: providerName) { return sidecar }
        guard let text = await TagReader.lyrics(song), let format = timedFormat(text) else { return nil }
        return RawLyrics(format: format, body: text, providerName: providerName)
    }

    static func sidecar(for song: URL, providerName: String) -> RawLyrics? {
        let folder = song.deletingLastPathComponent()
        let stem = song.deletingPathExtension().lastPathComponent.lowercased()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let lyricFiles = names.filter { sidecarExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        let exact = lyricFiles.filter { ($0 as NSString).deletingPathExtension.lowercased() == stem }
        let candidates: [String]
        if !exact.isEmpty {
            candidates = exact
        } else {
            let title = FileName(song.lastPathComponent).title.lowercased()
            let containing = lyricFiles.filter { ($0 as NSString).deletingPathExtension.lowercased().contains(title) }
            candidates = title.count >= 2 && Set(containing.map { ($0 as NSString).deletingPathExtension.lowercased() }).count == 1 ? containing : []
        }
        for ext in sidecarExtensions {
            guard let name = candidates.first(where: { ($0 as NSString).pathExtension.lowercased() == ext }),
                  let data = try? Data(contentsOf: folder.appending(path: name)) else { continue }
            let text = ext == "krc" ? LyricsFile(name: name, data: data)?.text : TextRepair.decodeText(data)
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let format = LyricsFormatDetector.detect(text)
            guard let parsed = try? LyricsParsing.parse(text, format: format), !parsed.isEmpty,
                  let wire = RawLyrics.Format(rawValue: format.rawValue) else { continue }
            return RawLyrics(format: wire, body: text, providerName: providerName)
        }
        return nil
    }

    /// The format of tag lyrics that have times (LRC, TTML…); nil for plain text.
    static func timedFormat(_ text: String) -> RawLyrics.Format? {
        let format = LyricsFormatDetector.detect(text)
        guard let parsed = try? LyricsParsing.parse(text, format: format), !parsed.isEmpty else { return nil }
        return RawLyrics.Format(rawValue: format.rawValue)
    }
}
