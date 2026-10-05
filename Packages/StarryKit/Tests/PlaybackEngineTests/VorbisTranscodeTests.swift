import AVFoundation
import Foundation
import StarryCore
import Testing
@testable import PlaybackEngine

/// Synthetic fixtures generated once per test process with ffmpeg (libvorbis / libopus):
/// - halves.ogg: 30 s, stereo, 44.1 kHz; 15 s of silence, then 15 s of a chord with noise.
/// - mono48.ogg: 6 s, mono, 48 kHz; 3 s of silence, then a 440 Hz tone.
/// - opus.ogg: 3 s of Opus.
enum OggFixture {
    private static let folder: Result<URL, Error> = Result {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "starry-ogg-fixtures-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            // Fixed noise seed; silence compresses much more than the chord and noise, so
            // seeking must use granules rather than estimate a byte offset from the duration.
            try generate("halves", in: folder, arguments: [
                "-f", "lavfi", "-i", "anoisesrc=amplitude=0.1:sample_rate=44100:duration=15:seed=42",
                "-f", "lavfi", "-i", "aevalsrc=0.25*(sin(2*PI*220*t)+sin(2*PI*330*t)+sin(2*PI*440*t)):s=44100:d=15",
                "-f", "lavfi", "-i", "anoisesrc=amplitude=0.1:sample_rate=44100:duration=15:seed=43",
                "-filter_complex", "[1:a]asplit=2[cl][cr];"
                    + "[0:a][cl]amix=inputs=2:normalize=0[l];[2:a][cr]amix=inputs=2:normalize=0[r];"
                    + "[l][r]join=inputs=2:channel_layout=stereo,adelay=15000:all=1",
                "-ac", "2", "-c:a", "libvorbis", "-q:a", "5",
                // Keep several pages in the reader's 16 KiB tail fetch for tail-prefill tests.
                "-page_duration", "200000",
            ])
            try generate("mono48", in: folder, arguments: [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3",
                "-af", "adelay=3000:all=1", "-ac", "1", "-c:a", "libvorbis", "-q:a", "5",
            ])
            try generate("opus", in: folder, arguments: [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3",
                "-ac", "2", "-c:a", "libopus", "-b:a", "128k",
            ])
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func generate(_ name: String, in folder: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
            + arguments + [folder.appending(path: "\(name).ogg").path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "OggFixture", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Ogg fixture generation failed; install ffmpeg with libvorbis and libopus and make it available on PATH.",
            ])
        }
    }

    static func url(_ name: String) throws -> URL { try folder.get().appending(path: "\(name).ogg") }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
}

@Suite struct OggVorbisTests {
    @Test func packetLengthsAddUpToTheLastGranule() throws {
        let bytes = [UInt8](try OggFixture.data("halves"))
        var pages: [OggPage] = []
        var offset = 0
        while offset < bytes.count, let page = OggPage.parse(bytes, at: offset, offset: Int64(offset)) {
            pages.append(page)
            offset += page.size
        }
        #expect(offset == bytes.count)
        var packets: [[UInt8]] = []
        var partial: [UInt8] = []
        for page in pages {
            for piece in page.pieces() {
                partial += piece.bytes
                if piece.complete { packets.append(partial); partial = [] }
            }
        }
        let headers = try VorbisHeaders(identification: packets[0], comment: packets[1], setup: packets[2])
        #expect(headers.sampleRate == 44_100 && headers.channels == 2)
        #expect(headers.shortBlock == 256 && headers.longBlock == 2048 && headers.modeIsLong == [false, true])
        var total = 0
        var previous: Int?
        for packet in packets[3...] {
            if let previous { total += headers.duration(packet, previousBlocksize: previous) }
            previous = headers.blocksize(packet)
        }
        let last = try #require(pages.last).granule
        #expect(Int64(total) >= last && Int64(total) - last < 2048, "packets \(total), last granule \(last)")
    }

    @Test func damagedPageFailsItsChecksum() throws {
        var bytes = [UInt8](try OggFixture.data("halves"))
        let first = try #require(OggPage.parse(bytes, at: 0, offset: 0))
        bytes[first.headerSize + 5] ^= 0x40
        #expect(OggPage.parse(bytes, at: 0, offset: 0) == nil)
    }

    @Test func opusIsNotVorbis() throws {
        let reader = OggVorbisReader(source: LocalFileSource(url: try OggFixture.url("opus")))
        #expect(throws: OggVorbisError.notVorbis) { try reader.open() }
    }

    @Test func lengthAndFormatComeFromThePages() throws {
        let reader = OggVorbisReader(source: LocalFileSource(url: try OggFixture.url("mono48")))
        try reader.open()
        #expect(reader.headers.channels == 1 && reader.headers.sampleRate == 48_000)
        #expect(reader.origin == 0)
        #expect(reader.totalFrames == 6 * 48_000)
    }

    @Test func decodingFromAnyPositionMatchesTheDecodeFromTheStart() async throws {
        let url = try OggFixture.url("halves")
        let reference = try Self.decodeFromStart(url)
        let directory = FileManager.default.temporaryDirectory.appending(path: "vorbis-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // A short window, so the positions below are reached by seeking, not by reading ahead.
        let transcode = VorbisTranscode(source: LocalFileSource(url: url), directory: directory, decodeAhead: 1)
        defer { transcode.cancel() }
        transcode.start()
        try await Self.waitUntil { transcode.isReady }
        let total = Int64(reference.count / 2)
        try await Self.waitUntil { transcode.decodedFrames.last?.upperBound == total }
        for seconds in [22.2, 7.3, 15.0, 29.0, 0.4] {
            let start = Int64(seconds * 44_100)
            let frames = start..<min(total, start + 8192)
            transcode.need(frame: start)
            try await Self.waitUntil { transcode.samples(frames) != nil }
            let decoded = try #require(transcode.samples(frames))
            let expected = Array(reference[Int(frames.lowerBound) * 2..<Int(frames.upperBound) * 2])
            let worst = zip(decoded, expected).map { abs($0 - $1) }.max() ?? 0
            #expect(worst < 1e-6, "at \(seconds) s: off by \(worst)")
        }
        #expect(transcode.seeks >= 3)
    }

    static func decodeFromStart(_ url: URL) throws -> [Float] {
        let reader = OggVorbisReader(source: LocalFileSource(url: url))
        try reader.open()
        let decoder = try VorbisDecoder(headers: reader.headers)
        let packets = OggPacketReader(fromStartOf: reader)
        decoder.input = { packets.next() }
        let channels = reader.headers.channels
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * channels)
        defer { buffer.deallocate() }
        var out: [Float] = []
        while true {
            let result = decoder.decode(into: buffer, frames: 4096)
            if result.frames == 0 { break }
            out.append(contentsOf: UnsafeBufferPointer(start: buffer, count: result.frames * channels))
        }
        return Array(out.prefix(Int(reader.totalFrames) * channels))
    }

    private static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
@Suite(.serialized) struct VorbisTranscodeEngineTests {
    /// A streamed file: exact duration from the start, and a seek into bytes not downloaded yet
    /// plays what is there.
    @Test func streamedVorbisSeeksExactly() async throws {
        let (url, server) = try StubRangeProtocol.register(OggFixture.data("halves"), name: "song.ogg", bytesPerSecond: 60_000)
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.volume = 0
        defer { engine.stop() }
        try await engine.load(Self.asset(url), track: TrackRef(source: .local, id: "ogg"), autoplay: true)
        try await Self.waitUntil { engine.duration > 0 }
        #expect(engine.active.isTranscoding)
        #expect(abs(engine.duration - 30) < 0.001, "duration \(engine.duration)")
        #expect(server.served < server.size, "served \(server.served) of \(server.size)")
        let transcode = try #require(engine.active.transcoder)
        #expect(!transcode.decodedFrames.contains { $0.contains(25 * 44_100) }, "\(transcode.decodedFrames)")

        await engine.seek(to: 25)
        try await Self.waitUntil(timeout: .seconds(8)) { engine.currentTime > 25.5 }
        #expect(engine.spectrumSnapshot().overall > 0.2, "at 25 s: \(engine.spectrumSnapshot().overall)")
        #expect(engine.currentTime < 28)

        await engine.seek(to: 3)
        try await Self.waitUntil(timeout: .seconds(2)) { engine.spectrumSnapshot().overall < 0.05 }
        #expect(engine.currentTime < 5)
        try await Self.waitUntil(timeout: .seconds(10)) { server.served >= server.size }
        #expect(server.served <= server.size + 2 * StubRangeProtocol.chunk, "served \(server.served) of \(server.size)")
    }

    @Test func scrambledVorbisIsKeptPlainAndTranscoded() async throws {
        let plain = try OggFixture.data("halves")
        var scrambled = plain
        scrambled.withUnsafeMutableBytes { PositionScrambler().decrypt($0, at: 0) }
        let (url, _) = try StubRangeProtocol.register(scrambled, name: "song.mgg")
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.keepsDownloads = true
        engine.volume = 0
        defer { engine.stop() }
        let finished = FinishedFile()
        let watcher = Task { @MainActor in
            for await event in engine.events {
                if case .downloadFinished(_, let file) = event { finished.url = file }
            }
        }
        defer { watcher.cancel() }
        var asset = Self.asset(url)
        asset.decryption = StreamDecryption(id: "xor", decryptor: PositionScrambler())
        try await engine.load(asset, track: TrackRef(source: .example, id: "scrambled"), autoplay: true)
        try await Self.waitUntil { finished.url != nil && engine.duration > 0 }
        let file = try #require(finished.url)
        #expect(file.pathExtension == "ogg")
        #expect(try Data(contentsOf: file) == plain)
        #expect(engine.active.isTranscoding && !engine.active.hasPreciseCopy)

        await engine.seek(to: 20)
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.spectrumSnapshot().overall > 0.2, "at 20 s: \(engine.spectrumSnapshot().overall)")
    }

    @Test func localMonoFileTranscodes() async throws {
        let engine = AVDeckEngine()
        engine.volume = 0
        defer { engine.stop() }
        let asset = PlayableAsset(url: try OggFixture.url("mono48"), container: .ogg, tier: QualityTier(.hq), supportsTap: true, provider: .local)
        try await engine.load(asset, track: TrackRef(source: .local, id: "mono"), autoplay: true)
        try await Self.waitUntil { engine.duration > 0 }
        #expect(engine.active.isTranscoding)
        #expect(abs(engine.duration - 6) < 0.001, "duration \(engine.duration)")
        await engine.seek(to: 4.2)
        try await Self.waitUntil(timeout: .seconds(2)) { engine.spectrumSnapshot().overall > 0.03 }
        await engine.seek(to: 0.3)
        try await Self.waitUntil(timeout: .seconds(2)) { engine.spectrumSnapshot().overall < 0.005 }
        #expect(engine.currentTime < 2.5)
        let format = try #require(await engine.currentFormat())
        #expect(format.sampleRate == 48_000 && format.channels == 1)
        #expect((format.bitrate ?? 0) > 0 && (format.bitrate ?? 0) < 320_000, "bitrate \(String(describing: format.bitrate))")
    }

    @Test func decodesOnlyAheadOfThePlayhead() async throws {
        let ahead = VorbisTranscode.decodeAhead
        VorbisTranscode.decodeAhead = 4
        defer { VorbisTranscode.decodeAhead = ahead }
        let engine = AVDeckEngine()
        engine.volume = 0
        defer { engine.stop() }
        let asset = PlayableAsset(url: try OggFixture.url("halves"), container: .ogg, tier: QualityTier(.hq), supportsTap: true, provider: .local)
        try await engine.load(asset, track: TrackRef(source: .local, id: "ahead"), autoplay: true)
        try await Self.waitUntil { engine.currentTime > 1 }
        let transcode = try #require(engine.active.transcoder)
        try await Task.sleep(for: .milliseconds(500))
        let rate = 44_100.0
        let decoded = transcode.decodedFrames
        let start = try #require(decoded.first)
        #expect(start.lowerBound == 0)
        #expect(Double(start.upperBound) / rate < engine.currentTime + 4 + 2 + 0.5, "decoded to \(Double(start.upperBound) / rate) s at \(engine.currentTime) s")
        #expect(decoded.count == 2 && Double(decoded[1].lowerBound) / rate > 29)

        await engine.seek(to: 15)
        try await Task.sleep(for: .milliseconds(600))
        let after = transcode.decodedFrames
        #expect(after.contains { Double($0.lowerBound) / rate <= 15 && Double($0.upperBound) / rate >= 17 }, "\(after)")
        #expect(!after.contains { $0.contains(Int64(26 * rate)) }, "decoded too far: \(after)")
    }

    /// Opus in Ogg is left to AVFoundation (it decodes it in short runs).
    @Test func opusFallsBackToTheSystemDecoder() async throws {
        let engine = AVDeckEngine()
        engine.volume = 0
        defer { engine.stop() }
        let asset = PlayableAsset(url: try OggFixture.url("opus"), container: .ogg, tier: QualityTier(.hq), supportsTap: true, provider: .local)
        try await engine.load(asset, track: TrackRef(source: .local, id: "opus"), autoplay: true)
        try await Self.waitUntil { engine.duration > 0 && !engine.active.isTranscoding }
        #expect(abs(engine.duration - 3) < 0.1, "duration \(engine.duration)")
        try await Self.waitUntil { engine.currentTime > 0.5 }
    }

    private static func asset(_ url: URL) -> PlayableAsset {
        PlayableAsset(url: url, container: .ogg, tier: QualityTier(.hq), supportsTap: true, provider: .source)
    }

    private static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
