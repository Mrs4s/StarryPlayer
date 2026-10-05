import AudioProcessing
import Foundation
import Library
import LyricsCore
import LyricsSync
import StarryCore

/// Key offsets by lyric content as well as song: different sources may use different timing.
@MainActor
final class LyricOffsetStore {
    struct Entry: Codable {
        var offset: TimeInterval
        var calibrated: Bool
        var savedAt: Date
    }

    private static let fileName = "lyric-offsets"
    private static let limit = 2000
    private let directory: DataDirectory?
    private var entries: [String: Entry]

    /// nil keeps the offsets in memory only (tests, a launch without `keepsData`).
    init(directory: DataDirectory?) {
        self.directory = directory
        entries = directory?.readCodable([String: Entry].self, name: Self.fileName) ?? [:]
    }

    func entry(for key: String) -> Entry? { entries[key] }

    var count: Int { entries.count }

    func removeAll() {
        entries.removeAll()
        if let directory { directory.delete(Self.fileName) }
    }

    func set(_ offset: TimeInterval, calibrated: Bool, for key: String) {
        if offset == 0, !calibrated {
            entries[key] = nil
        } else {
            entries[key] = Entry(offset: offset, calibrated: calibrated, savedAt: Date())
        }
        if entries.count > Self.limit {
            for (key, _) in entries.sorted(by: { $0.value.savedAt < $1.value.savedAt }).prefix(entries.count - Self.limit) {
                entries[key] = nil
            }
        }
        try? directory?.writeCodable(entries, name: Self.fileName)
    }

    static func key(track: TrackRef, lyrics: LyricsDocument) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
        }
        mix(lyrics.format.rawValue)
        for line in lyrics.lines {
            mix("\n\(Int((line.start * 1000).rounded()))|\(line.text)")
        }
        return "\(track.description)#\(String(hash, radix: 16))"
    }
}

enum LyricCalibrationState: Equatable {
    case idle
    case running(key: String)

    var isRunning: Bool { self != .idle }
}

enum LyricCalibrationError: Error {
    /// HLS, a 30 s trial or a source the engine does not play: no file to analyse.
    case unsupportedSource(String)
    case download(Int)
}

enum LyricCalibrationAudio {
    struct File: Sendable {
        var url: URL
        var isTemporary: Bool
    }

    static func file(for asset: PlayableAsset) async throws -> File {
        guard asset.container != .hls else { throw LyricCalibrationError.unsupportedSource("当前音源无法校准歌词") }
        if asset.url.isFileURL { return File(url: asset.url, isTemporary: false) }
        var request = URLRequest(url: asset.url, timeoutInterval: 30)
        for (field, value) in asset.headers { request.setValue(value, forHTTPHeaderField: field) }
        let (download, response) = try await URLSession.shared.download(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            try? FileManager.default.removeItem(at: download)
            throw LyricCalibrationError.download(status)
        }
        let pathExtension = asset.url.pathExtension.isEmpty || asset.decryption != nil ? Self.pathExtension(for: asset.container) : asset.url.pathExtension
        let destination = FileManager.default.temporaryDirectory.appending(path: "starry-calibration-\(UUID().uuidString).\(pathExtension)")
        if let decryption = asset.decryption {
            defer { try? FileManager.default.removeItem(at: download) }
            var data = try Data(contentsOf: download)
            data.withUnsafeMutableBytes { decryption.decryptor.decrypt($0, at: 0) }
            try data.write(to: destination)
        } else {
            try FileManager.default.moveItem(at: download, to: destination)
        }
        return File(url: destination, isTemporary: true)
    }

    private static func pathExtension(for container: AudioContainer) -> String {
        switch container {
        case .aac, .alac: "m4a"
        default: container.rawValue
        }
    }

    /// Runs `calibrator` off the main thread; cancelling the calling task stops it between windows.
    static func calibrate(_ file: File, document: LyricsDocument, model: VocalSeparationModel) async throws -> LyricsCalibration {
        let work = Task.detached(priority: .userInitiated) { () throws -> LyricsCalibration in
            let calibrator = LyricsCalibrator()
            do {
                return try calibrator.calibrate(audio: file.url, document: document, model: model, isCancelled: { Task.isCancelled })
            } catch VocalActivityError.separationUnavailable {
                // No network takes this audio: the mix still carries word-timed lyrics.
                return try calibrator.calibrate(audio: file.url, document: document, model: nil, isCancelled: { Task.isCancelled })
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    static func message(for error: Error) -> String {
        switch error {
        case LyricCalibrationError.unsupportedSource(let message): message
        case LyricCalibrationError.download(let status): "下载音频失败（HTTP \(status)），无法校准歌词"
        case VocalActivityError.unreadable: "无法读取音频，无法校准歌词"
        case VocalActivityError.unsupportedFormat: "不支持多声道音频的歌词校准"
        case VocalActivityError.separationUnavailable: "人声分离不可用，无法校准歌词"
        default: "歌词校准失败：\(ErrorText.describe(error))"
        }
    }

    /// The offset was not changed: why, without claiming the lyrics are wrong when the audio
    /// only did not show it clearly.
    static func message(for failure: LyricsCalibration.Failure) -> String {
        switch failure {
        case .tooLittle: "没能校准：这首歌可用来对齐的演唱或歌词太少"
        case .noClearMatch: "没能校准：没找到歌词和演唱明确对应的位置"
        case .inconsistent: "没能校准：歌词各段的偏移不一致，无法整体调整"
        }
    }
}
