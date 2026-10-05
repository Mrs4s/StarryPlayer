import Foundation
import Library
import LyricsProviders
import StarryCore

@MainActor
final class LyricSourcePins {
    private struct Entry: Codable {
        var source: String
        var savedAt: Date
        var song: LyricsSearchResult?
        var file: LyricsFile?

        init(_ pin: LyricsPin) {
            savedAt = Date()
            switch pin {
            case .source(let candidate): source = candidate.key
            case .song(let result): source = "song"; song = result
            case .file(let lyricsFile): source = "file"; file = lyricsFile
            }
        }

        var pin: LyricsPin? {
            switch source {
            case "song": song.map(LyricsPin.song)
            case "file": file.map(LyricsPin.file)
            default: LyricsCandidateSource(key: source).map(LyricsPin.source)
            }
        }
    }

    private static let fileName = "lyric-sources"
    private static let limit = 2000
    private let directory: DataDirectory?
    private var entries: [String: Entry]

    /// nil keeps the pins in memory only (tests, a launch without `keepsData`).
    init(directory: DataDirectory?) {
        self.directory = directory
        entries = directory?.readCodable([String: Entry].self, name: Self.fileName) ?? [:]
    }

    func pin(for track: TrackRef) -> LyricsPin? {
        entries[Self.key(track)]?.pin
    }

    /// nil unpins.
    func set(_ pin: LyricsPin?, for track: TrackRef) {
        entries[Self.key(track)] = pin.map(Entry.init)
        if entries.count > Self.limit {
            for (key, _) in entries.sorted(by: { $0.value.savedAt < $1.value.savedAt }).prefix(entries.count - Self.limit) {
                entries[key] = nil
            }
        }
        try? directory?.writeCodable(entries, name: Self.fileName)
    }

    private static func key(_ track: TrackRef) -> String { track.description }
}
