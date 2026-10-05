import AVFoundation
import Foundation

/// Tags AVFoundation reads well (MP4 atoms, Vorbis comments in Ogg, RIFF / CAF INFO, ID3 in AIFF),
/// mapped to canonical keys — its `commonMetadata` is empty for Vorbis comments — and the audio's
/// format, length and whether the system plays it.
enum AVFoundationTags {
    struct Result {
        var tags = RawTags()
        var picture: EmbeddedPicture?
        var audio: AudioProperties
        var isPlayable: Bool
    }

    static func read(_ url: URL, tags readsTags: Bool = true, lyrics: Bool = false, precise: Bool = false) async -> Result? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: precise])
        guard let (duration, playable, formats) = try? await asset.load(.duration, .isPlayable, .availableMetadataFormats),
              let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        var result = Result(audio: await audio(of: track, duration: duration.seconds, url: url), isPlayable: playable)
        // Ogg FLAC lists as playable but does not decode.
        if url.pathExtension.lowercased() != "flac", result.audio.codec == "flac", ["ogg", "oga"].contains(url.pathExtension.lowercased()) {
            result.isPlayable = false
        }
        guard readsTags else { return result }
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            for item in items { await add(item, to: &result, lyrics: lyrics) }
        }
        return result
    }

    /// The lyrics AVFoundation finds in a file (`©lyr`, USLT, Vorbis `LYRICS`).
    static func lyrics(_ url: URL) async -> String? {
        guard let result = await read(url, lyrics: true) else { return nil }
        return result.tags.first(TagKey.lyrics)
    }

    private static func add(_ item: AVMetadataItem, to result: inout Result, lyrics: Bool) async {
        guard let identifier = item.identifier?.rawValue, let slash = identifier.firstIndex(of: "/") else { return }
        let space = identifier[..<slash]
        // `©` is `%A9` in the identifier: the atom's Mac Roman byte, not UTF-8.
        let raw = String(identifier[identifier.index(after: slash)...]).replacingOccurrences(of: "%A9", with: "©")
        let name = raw.removingPercentEncoding ?? raw
        switch space {
        case "id3":
            await addID3(name, item, to: &result, lyrics: lyrics)
        case "itsk":
            await addITunes(name, item, to: &result, lyrics: lyrics)
        case "vorb":
            if name == "METADATA_BLOCK_PICTURE" {
                await addPicture(item, type: 3, to: &result)
            } else if let key = TagKey.canonical(name), lyrics || key != TagKey.lyrics, let value = try? await item.load(.stringValue) {
                result.tags.add(value, for: key)
            }
        case "caaf", "udta", "mdta", "itlk":
            var last = name
            if last.hasPrefix("info-") { last = String(last.dropFirst(5)) }
            if let separator = last.lastIndex(where: { $0 == "." || $0 == ":" }) { last = String(last[last.index(after: separator)...]) }
            if let key = TagKey.canonical(last), lyrics || key != TagKey.lyrics, let value = try? await item.load(.stringValue) {
                result.tags.add(value, for: key)
            }
        default:
            break
        }
    }

    private static func addID3(_ frame: String, _ item: AVMetadataItem, to result: inout Result, lyrics: Bool) async {
        if let key = TagKey.id3Frames[frame], let value = try? await item.load(.stringValue) {
            result.tags.add(key == TagKey.genre ? Genres.id3v2(value) : [value], for: key)
            return
        }
        switch frame {
        case "TXXX":
            let extra = (try? await item.load(.extraAttributes)) ?? [:]
            guard let description = extra[.info] as? String, let key = TagKey.canonical(description), let value = try? await item.load(.stringValue) else { return }
            result.tags.add(value, for: key)
        case "USLT":
            if lyrics, let value = try? await item.load(.stringValue) { result.tags.add(value, for: TagKey.lyrics) }
        case "APIC":
            let extra = (try? await item.load(.extraAttributes)) ?? [:]
            let front = (extra[.init(rawValue: "pictureType")] as? String).map { $0.lowercased().contains("front") } ?? true
            await addPicture(item, type: front ? 3 : 0, to: &result)
        default:
            break
        }
    }

    private static func addITunes(_ atom: String, _ item: AVMetadataItem, to result: inout Result, lyrics: Bool) async {
        let keys: [String: String] = [
            "©nam": TagKey.title, "©ART": TagKey.artist, "aART": TagKey.albumArtist, "©alb": TagKey.album,
            "©day": TagKey.date, "©gen": TagKey.genre, "©wrt": TagKey.composer, "sonm": TagKey.titleSort,
            "soar": TagKey.artistSort, "soaa": TagKey.albumArtistSort, "soal": TagKey.albumSort,
        ]
        if let key = keys[atom] {
            if let value = try? await item.load(.stringValue) { result.tags.add(value, for: key) }
            return
        }
        switch atom {
        case "trkn", "disk":
            // MP4 track/disc layout: `00 00 nn nn tt tt [00 00]` (number, total).
            guard let data = try? await item.load(.dataValue), data.count >= 6 else { return }
            let number = Int(data.bigEndian(at: 2, count: 2))
            let total = Int(data.bigEndian(at: 4, count: 2))
            let isTrack = atom == "trkn"
            if number > 0 { result.tags.add(String(number), for: isTrack ? TagKey.track : TagKey.disc) }
            if total > 0 { result.tags.add(String(total), for: isTrack ? TagKey.trackTotal : TagKey.discTotal) }
        case "gnre":
            // MP4 genre values are one-based ID3v1 indices.
            guard let data = try? await item.load(.dataValue), data.count >= 2 else { return }
            let index = Int(data.bigEndian(at: 0, count: 2)) - 1
            if index >= 0, index < Genres.id3v1.count { result.tags.add(Genres.id3v1[index], for: TagKey.genre) }
        case "cpil":
            var value = (try? await item.load(.numberValue))?.intValue
            if value == nil { value = (try? await item.load(.stringValue)).flatMap { Int($0) } }
            if (value ?? 0) != 0 { result.tags.add("1", for: TagKey.compilation) }
        case "©lyr":
            if lyrics, let value = try? await item.load(.stringValue) { result.tags.add(value, for: TagKey.lyrics) }
        case "covr":
            await addPicture(item, type: 3, to: &result)
        default:
            break
        }
    }

    private static func addPicture(_ item: AVMetadataItem, type: Int, to result: inout Result) async {
        if let current = result.picture, current.isFrontCover || type != 3 { return }
        guard let data = try? await item.load(.dataValue), !data.isEmpty else { return }
        result.picture = EmbeddedPicture(length: data.count, data: data, type: type)
    }

    private static func audio(of track: AVAssetTrack, duration: TimeInterval, url: URL) async -> AudioProperties {
        var audio = AudioProperties(codec: url.pathExtension.lowercased(), duration: duration.isFinite ? duration : 0)
        guard let (descriptions, rate) = try? await track.load(.formatDescriptions, .estimatedDataRate),
              let description = descriptions.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return audio }
        audio.sampleRate = asbd.mSampleRate > 0 ? Int(asbd.mSampleRate) : nil
        audio.channels = asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : nil
        switch asbd.mFormatID {
        case kAudioFormatMPEGLayer3: audio.codec = "mp3"
        case kAudioFormatMPEGLayer2: audio.codec = "mp2"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD: audio.codec = "aac"
        case kAudioFormatAppleLossless:
            audio.codec = "alac"
            audio.bitDepth = losslessBits(asbd.mFormatFlags)
        case kAudioFormatFLAC:
            audio.codec = "flac"
            audio.bitDepth = losslessBits(asbd.mFormatFlags)
        case kAudioFormatLinearPCM:
            audio.codec = "pcm"
            audio.bitDepth = asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
        case kAudioFormatOpus: audio.codec = "opus"
        case kAudioFormatAC3: audio.codec = "ac3"
        case kAudioFormatEnhancedAC3: audio.codec = "eac3"
        case 0x766F_7262: audio.codec = "vorbis"   // 'vorb'
        default: break
        }
        if rate > 0 {
            audio.bitrate = Int(rate)
        } else if audio.duration > 0, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            audio.bitrate = Int(Double(size) * 8 / audio.duration)
        }
        return audio
    }

    /// ALAC and FLAC store source bit depth in the format flags.
    private static func losslessBits(_ flags: AudioFormatFlags) -> Int? {
        switch flags {
        case 1: 16
        case 2: 20
        case 3: 24
        case 4: 32
        default: nil
        }
    }
}
