import Foundation
import Testing
@testable import LocalLibrary

struct TagReaderTests {
    @Test func id3v24KeepsEveryValue() async throws {
        let file = try #require(await TagReader.read(corpusFile("01 v24 utf8.mp3")))
        #expect(file.reader == "id3v2")
        #expect(file.tags[TagKey.title] == ["测试标题 v2.4"])
        // AVFoundation gives only the first of these.
        #expect(file.tags[TagKey.artist] == ["歌手甲", "Singer B"])
        #expect(file.tags[TagKey.albumArtist] == ["专辑歌手"])
        #expect(file.tags[TagKey.track] == ["3/12"])
        #expect(file.tags[TagKey.disc] == ["1/2"])
        #expect(file.tags[TagKey.date] == ["2021-05-20"])
        #expect(file.tags[TagKey.compilation] == ["1"])
        #expect(file.tags[TagKey.artistSort] == ["geshou jia"])
        #expect(file.tags[TagKey.trackGain] == ["-7.50 dB"])
        #expect(file.tags[TagKey.musicBrainzAlbum] == ["0f3f2f6e-1111-2222-3333-444455556666"])
        #expect(file.tags[TagKey.artists] == ["歌手甲"])
        #expect(file.tags[TagKey.lyrics].isEmpty)
        let picture = try #require(file.picture)
        #expect(picture.isFrontCover)
        #expect(picture.data == nil)
        let bytes = try #require(picture.bytes(in: corpusFile("01 v24 utf8.mp3")))
        #expect(bytes.starts(with: [0xFF, 0xD8]))
        #expect(file.audio.codec == "mp3")
        #expect(file.audio.sampleRate == 44100)
        #expect(abs(file.audio.duration - 1) < 0.1)
    }

    @Test func id3v23UTF16AndGenreNumbers() async throws {
        let file = try #require(await TagReader.read(corpusFile("02 v23 utf16.mp3")))
        #expect(file.tags[TagKey.artist] == ["歌手甲/歌手乙"])
        #expect(file.tags[TagKey.genre] == ["Pop"])
        #expect(file.tags[TagKey.date] == ["2021"])
    }

    /// GBK bytes in an ISO-8859-1 frame stay Latin-1 characters for the repair.
    @Test func legacyBytesComeOutAsLatin1() async throws {
        let gbk = try #require(await TagReader.read(corpusFile("03 v23 gbk.mp3")))
        let title = try #require(gbk.tags.first(TagKey.title))
        #expect(TextRepair.repaired(title, as: .gb18030) == "国标编码标题")
        let v1 = try #require(await TagReader.read(corpusFile("04 v1 gbk.mp3")))
        #expect(v1.reader == "id3v1")
        #expect(v1.tags.first(TagKey.artist).flatMap { TextRepair.repaired($0, as: .gb18030) } == "陈奕迅")
        #expect(v1.tags[TagKey.track] == ["3"])
        #expect(v1.tags[TagKey.genre] == ["Pop"])
    }

    @Test func untaggedFile() async throws {
        let file = try #require(await TagReader.read(corpusFile("05 林俊杰 - 江南.mp3")))
        #expect(file.tags.isEmpty)
        #expect(file.reader == "none")
    }

    @Test func flacVorbisComment() async throws {
        let file = try #require(await TagReader.read(corpusFile("06 flac multi.flac")))
        #expect(file.reader == "flac")
        #expect(file.tags[TagKey.artist] == ["歌手甲", "Singer B"])
        #expect(file.tags[TagKey.genre] == ["Rock", "Live"])
        #expect(file.tags[TagKey.albumArtist] == ["Various Artists"])
        #expect(file.tags[TagKey.trackTotal] == ["15"])
        #expect(file.tags[TagKey.musicBrainzTrack] == ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"])
        #expect(file.audio.sampleRate == 96000)
        #expect(file.audio.bitDepth == 24)
        #expect(abs(file.audio.duration - 1) < 0.01)
        #expect(file.picture?.isFrontCover == true)
        #expect(try file.picture?.bytes(in: corpusFile("06 flac multi.flac"))?.starts(with: [0xFF, 0xD8]) == true)
    }

    /// AVFoundation reads only the ID3 tag in front; the Vorbis comment is the real one.
    @Test func flacBehindID3() async throws {
        let file = try #require(await TagReader.read(corpusFile("07 flac id3 prefix.flac")))
        #expect(file.reader == "flac+id3v2")
        #expect(file.tags[TagKey.title] == ["FLAC 带 ID3 头"])
        #expect(file.tags[TagKey.artist] == ["某歌手"])
    }

    @Test func mp4Atoms() async throws {
        let aac = try #require(await TagReader.read(corpusFile("08 aac.m4a")))
        #expect(aac.reader == "avf")
        #expect(aac.tags[TagKey.title] == ["AAC 标题"])
        #expect(aac.tags[TagKey.albumArtist] == ["歌手甲"])
        #expect(aac.tags[TagKey.track] == ["2"])
        #expect(aac.tags[TagKey.trackTotal] == ["9"])
        #expect(aac.tags[TagKey.compilation] == ["1"])
        #expect(aac.picture?.data?.starts(with: [0xFF, 0xD8]) == true)
        #expect(aac.audio.codec == "aac")
        let alac = try #require(await TagReader.read(corpusFile("09 alac 24-96.m4a")))
        #expect(alac.audio.codec == "alac")
        #expect(alac.audio.bitDepth == 24)
        #expect(alac.audio.sampleRate == 96000)
    }

    @Test func oggFormats() async throws {
        let vorbis = try #require(await TagReader.read(corpusFile("10 vorbis.ogg")))
        #expect(vorbis.tags[TagKey.title] == ["Vorbis 标题"])
        #expect(vorbis.audio.codec == "vorbis")
        #expect(vorbis.picture != nil)
        let opus = try #require(await TagReader.read(corpusFile("11 opus.opus")))
        #expect(opus.audio.codec == "opus")
        #expect(opus.tags[TagKey.artist] == ["歌手甲;歌手乙"])
        // Listed as playable by AVFoundation, but does not decode.
        let oggFLAC = try #require(await TagReader.read(corpusFile("22 flac-in-ogg.oga")))
        #expect(!oggFLAC.isPlayable)
    }

    @Test func pcmContainers() async throws {
        let aiff = try #require(await TagReader.read(corpusFile("14 aiff id3.aiff")))
        #expect(aiff.tags[TagKey.title] == ["AIFF 标题"])
        #expect(aiff.audio.codec == "pcm")
        #expect(aiff.audio.bitDepth == 16)
        let wav = try #require(await TagReader.read(corpusFile("13 wav info.wav")))
        let artist = try #require(wav.tags.first(TagKey.artist))
        // RIFF INFO in UTF-8, read as Windows-1252.
        #expect(TextRepair.repaired(artist, as: .utf8) == "歌手甲")
        #expect(wav.audio.bitDepth == 24)
    }

    @Test func apeTagOnMP3() async throws {
        let file = try #require(await TagReader.read(corpusFile("23 ape only.mp3")))
        #expect(file.reader == "ape")
        #expect(file.tags[TagKey.title] == ["APE 标题"])
        #expect(file.tags[TagKey.track] == ["2"])
        #expect(try await TagReader.lyrics(corpusFile("23 ape only.mp3")) == "[00:01.00]APE 歌词")
    }

    /// Without a frame count the length is measured, not estimated from the first frames.
    @Test func vbrWithoutXingIsMeasured() async throws {
        let file = try #require(await TagReader.read(corpusFile("24 vbr no-xing.mp3")))
        #expect(abs(file.audio.duration - 4) < 0.1)
    }

    @Test func embeddedLyrics() async throws {
        #expect(try await TagReader.lyrics(corpusFile("01 v24 utf8.mp3")) == "[00:01.00]同步第一行\n[00:03.50]同步第二行")
        #expect(try await TagReader.lyrics(corpusFile("02 v23 utf16.mp3")) == "纯文本歌词第一行\n第二行")
        #expect(try await TagReader.lyrics(corpusFile("06 flac multi.flac"))?.hasPrefix("[00:01.00]第一行歌词") == true)
        #expect(try await TagReader.lyrics(corpusFile("08 aac.m4a"))?.hasPrefix("[00:01.00]第一行歌词") == true)
        #expect(try await TagReader.lyrics(corpusFile("10 vorbis.ogg"))?.hasPrefix("[00:01.00]第一行歌词") == true)
    }

    /// Some v2.4 writers put plain frame sizes; a size byte with its high bit set is no reason to
    /// fail (or crash).
    @Test func id3v24PlainFrameSizes() async throws {
        let title = String(repeating: "x", count: 199)
        var frame = Data("TIT2".utf8) + Data([0, 0, 0, 0xC8, 0, 0])
        frame += Data([3]) + Data(title.utf8)
        let size = frame.count + 64
        let header = Data("ID3".utf8) + Data([4, 0, 0, UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)])
        let url = FileManager.default.temporaryDirectory.appending(path: "plain-size-\(UUID().uuidString).mp3")
        try (header + frame + Data(count: 64) + Data(contentsOf: corpusFile("05 林俊杰 - 江南.mp3"))).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try #require(await TagReader.read(url))
        #expect(file.tags[TagKey.title] == [title])
    }

    @Test func formatsTheSystemCannotPlay() async throws {
        #expect(!TagReader.isAudio(try corpusFile("12 wavpack.wv")))
        #expect(TagReader.unsupportedExtensions.contains("wv"))
        #expect(TagReader.unsupportedExtensions.contains("wma"))
    }
}
