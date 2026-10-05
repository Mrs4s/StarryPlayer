import Foundation

/// Reads one audio file: the library's own readers where AVFoundation falls short (MP3's ID3v2
/// multi-values, APEv2, ID3v1; FLAC behind an ID3 tag), AVFoundation for the rest and for whether
/// the system plays the file.
public enum TagReader {
    public static let playableExtensions: Set<String> = [
        "mp3", "mp2", "m4a", "m4b", "mp4", "aac", "flac", "wav", "aif", "aiff", "aifc", "caf", "ogg", "oga", "opus", "ac3",
    ]

    /// Audio the system cannot play: counted, not listed.
    public static let unsupportedExtensions: Set<String> = ["ape", "wv", "dsf", "dff", "wma", "tta", "mpc", "tak", "mka", "m4p"]

    public static func isAudio(_ url: URL) -> Bool {
        playableExtensions.contains(url.pathExtension.lowercased())
    }

    /// The file's tags, audio and picture; nil when it cannot be read as audio.
    public static func read(_ url: URL) async -> FileTags? {
        switch url.pathExtension.lowercased() {
        case "mp3", "mp2": await readMP3(url)
        case "flac": await readFLAC(url)
        default: await readWithAVFoundation(url)
        }
    }

    public static func lyrics(_ url: URL) async -> String? {
        switch url.pathExtension.lowercased() {
        case "mp3", "mp2":
            guard let file = FileReader(url: url) else { return nil }
            let id3 = ID3v2.read(file, lyrics: true)
            if let synced = id3?.tags.first(TagKey.syncedLyrics) { return synced }
            if let lyrics = id3?.tags.first(TagKey.lyrics) { return lyrics }
            return APETag.read(file, lyrics: true)?.tags.first(TagKey.lyrics)
        case "flac":
            guard let file = FileReader(url: url), let info = FLACInfo.read(file, lyrics: true) else { return nil }
            return info.tags.first(TagKey.lyrics)
        default:
            return await AVFoundationTags.lyrics(url)
        }
    }

    private static func readMP3(_ url: URL) async -> FileTags? {
        guard let file = FileReader(url: url) else { return nil }
        var tags = RawTags()
        var picture: EmbeddedPicture?
        var readers: [String] = []
        let id3 = ID3v2.read(file)
        if let id3 {
            tags = id3.tags
            picture = id3.picture
            readers.append("id3v2")
        }
        if let ape = APETag.read(file) {
            tags.fill(from: ape.tags)
            picture = picture ?? ape.picture
            readers.append("ape")
        }
        if let v1 = ID3v2.readV1(file) {
            tags.fill(from: v1)
            readers.append("id3v1")
        }
        guard let frame = MPEGAudio.firstFrame(file, from: Int64(id3?.size ?? 0)) else { return nil }
        let codec = url.pathExtension.lowercased() == "mp2" ? "mp2" : "mp3"
        var audio = AudioProperties(codec: codec, duration: frame.duration ?? 0, sampleRate: frame.sampleRate, channels: frame.channels, bitrate: frame.bitrate)
        if frame.duration == nil {
            // Without a frame count, VBR duration requires reading the whole stream.
            guard let measured = await AVFoundationTags.read(url, tags: false, precise: true) else { return nil }
            audio.duration = measured.audio.duration
        }
        if frame.isVBR || frame.duration == nil, audio.duration > 0 {
            audio.bitrate = Int(Double(frame.audioBytes) * 8 / audio.duration)
        }
        return FileTags(tags: tags, audio: audio, picture: picture, isPlayable: true, reader: readers.isEmpty ? "none" : readers.joined(separator: "+"))
    }

    private static func readFLAC(_ url: URL) async -> FileTags? {
        guard let file = FileReader(url: url), let info = FLACInfo.read(file), let audio = info.audio else { return await readWithAVFoundation(url) }
        var tags = info.tags
        var reader = "flac"
        if let id3 = ID3v2.read(file) {
            tags.fill(from: id3.tags)
            reader += "+id3v2"
        }
        return FileTags(tags: tags, audio: audio, picture: info.picture, isPlayable: true, reader: reader)
    }

    private static func readWithAVFoundation(_ url: URL) async -> FileTags? {
        guard let result = await AVFoundationTags.read(url) else { return nil }
        return FileTags(tags: result.tags, audio: result.audio, picture: result.picture, isPlayable: result.isPlayable, reader: "avf")
    }
}
