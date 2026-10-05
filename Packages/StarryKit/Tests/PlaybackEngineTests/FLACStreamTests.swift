import AVFoundation
import Foundation
import StarryCore
import Testing
@testable import PlaybackEngine

@Suite struct ByteRangesTests {
    @Test func mergesTouchingAndOverlappingRanges() {
        var ranges = ByteRanges()
        ranges.insert(10..<20)
        ranges.insert(30..<40)
        ranges.insert(20..<25)
        #expect(ranges.ranges == [10..<25, 30..<40])
        ranges.insert(22..<35)
        #expect(ranges.ranges == [10..<40])
        ranges.insert(0..<5)
        #expect(ranges.ranges == [0..<5, 10..<40])
    }

    @Test func runsGapsAndCoverage() {
        var ranges = ByteRanges()
        ranges.insert(0..<100)
        ranges.insert(300..<400)
        #expect(ranges.end(ofRunAt: 50) == 100)
        #expect(ranges.end(ofRunAt: 150) == 150)
        #expect(ranges.start(after: 150) == 300)
        #expect(ranges.start(after: 350) == nil)
        #expect(ranges.firstGap(below: 500) == 100..<300)
        #expect(ranges.covers(10..<90))
        #expect(!ranges.covers(90..<310))
        ranges.insert(100..<300)
        #expect(ranges.firstGap(below: 500) == 400..<500)
        #expect(ranges.firstGap(below: 400) == nil)
    }
}

/// Streamed FLAC: AVFoundation's own FLAC seeks land seconds away from the time they
/// report. The test file is 15 s of silence and 15 s of noise, so nearly all its bytes are the
/// noise and a seek by estimate to 3 s plays noise; a correct one plays silence. (Muted: the
/// level is read before the volume.)
@MainActor
@Suite(.serialized) struct FLACStreamTests {
    @Test func seeksLandWhereTheyReportOnceTheFileIsIn() async throws {
        let (url, server) = try StubRangeProtocol.register(Self.testFile())
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.volume = 0
        defer { engine.stop() }
        try await engine.load(Self.asset(url), track: TrackRef(source: .local, id: "flac"), autoplay: true)
        try await Self.waitUntil { engine.active.hasPreciseCopy }
        #expect(server.served <= server.size + StubRangeProtocol.chunk)

        await engine.seek(to: 3)
        #expect(engine.active.isPlayingPreciseCopy)
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.spectrumSnapshot().overall < 0.05, "at 3 s: \(engine.spectrumSnapshot().overall)")
        #expect(engine.currentTime >= 3 && engine.currentTime < 5)

        await engine.seek(to: 25)
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.spectrumSnapshot().overall > 0.2, "at 25 s: \(engine.spectrumSnapshot().overall)")
    }

    @Test func seekByEstimateIsCorrectedWhenTheFileIsIn() async throws {
        let (url, server) = try StubRangeProtocol.register(Self.testFile(), bytesPerSecond: 1_000_000)
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.volume = 0
        defer { engine.stop() }
        try await engine.load(Self.asset(url), track: TrackRef(source: .local, id: "flac"), autoplay: true)
        try await Task.sleep(for: .milliseconds(300))
        await engine.seek(to: 3)
        #expect(!engine.active.hasPreciseCopy, "the download must still be running for this test")
        try await Task.sleep(for: .milliseconds(700))
        // What AVFoundation plays here is the bug being worked around (noise, i.e. past 15 s).
        print("level by estimate at \(engine.currentTime) s: \(engine.spectrumSnapshot().overall)")

        try await Self.waitUntil(timeout: .seconds(10)) { engine.active.isPlayingPreciseCopy }
        let switchedAt = engine.currentTime
        #expect(switchedAt > 3 && switchedAt < 10, "switched at \(switchedAt)")
        try await Self.waitUntil(timeout: .seconds(2)) { engine.currentTime > switchedAt + 0.3 }
        #expect(engine.spectrumSnapshot().overall < 0.05, "after the switch: \(engine.spectrumSnapshot().overall)")
        #expect(server.served <= server.size + 2 * StubRangeProtocol.chunk)
    }

    @Test func scrambledStreamPlaysUnscrambled() async throws {
        let plain = try Self.testFile()
        var scrambled = plain
        scrambled.withUnsafeMutableBytes { PositionScrambler().decrypt($0, at: 0) }
        let (url, server) = try StubRangeProtocol.register(scrambled, name: "song.mflac")
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
        try await Self.waitUntil { engine.active.hasPreciseCopy && finished.url != nil }
        let file = try #require(finished.url)
        #expect(file.pathExtension == "flac")
        #expect(try Data(contentsOf: file) == plain)
        #expect(server.served <= server.size + StubRangeProtocol.chunk)

        await engine.seek(to: 3)
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.spectrumSnapshot().overall < 0.05, "at 3 s: \(engine.spectrumSnapshot().overall)")
        await engine.seek(to: 25)
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.spectrumSnapshot().overall > 0.2, "at 25 s: \(engine.spectrumSnapshot().overall)")
    }

    /// A spatial mix (Dolby; a 5.1 AAC file in MPEG-4 stands in for E-AC-3, which the system
    /// decodes but cannot write): the system renders it, so no tap goes on, every layout may be
    /// spatialized, and vocal attenuation / the equalizer say why they are off. The scrambled
    /// file is kept plain under `.mp4`.
    @Test func spatialMixPlaysUntapped() async throws {
        let plain = try Self.surroundFile()
        var scrambled = plain
        scrambled.withUnsafeMutableBytes { PositionScrambler().decrypt($0, at: 0) }
        let (url, _) = try StubRangeProtocol.register(scrambled, name: "song.mmp4")
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
        var asset = PlayableAsset(url: url, container: .mp4, tier: QualityTier(id: "dolby", name: "杜比全景声", level: .hiRes, isSpatial: true), supportsTap: true, provider: .source)
        asset.decryption = StreamDecryption(id: "xor", decryptor: PositionScrambler())
        try await engine.load(asset, track: TrackRef(source: .example, id: "dolby"), autoplay: true)
        try await Self.waitUntil { finished.url != nil && engine.duration > 0 }
        let file = try #require(finished.url)
        #expect(file.pathExtension == "mp4")
        #expect(try Data(contentsOf: file) == plain)
        #expect(abs(engine.duration - 3) < 0.1, "duration \(engine.duration)")
        #expect(engine.active.playsSpatialMix)
        #expect(engine.active.player.currentItem?.allowedAudioSpatializationFormats == .monoStereoAndMultichannel)
        #expect(engine.active.processing == nil)
        #expect(engine.vocalStatus.unavailable == .spatialMix)
    }

    @Test func armedDownloadCarriesOver() async throws {
        let current = try Self.silentFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: current) }
        let (url, server) = try StubRangeProtocol.register(Self.testFile())
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.volume = 0
        defer { engine.stop() }
        let wav = PlayableAsset(url: current, container: .wav, tier: QualityTier(.lossless), supportsTap: false, provider: .local)
        try await engine.load(wav, track: TrackRef(source: .local, id: "current"), autoplay: true)
        await engine.arm(next: Self.asset(url), track: TrackRef(source: .local, id: "next"))
        try await Self.waitUntil { server.served >= server.size }

        try await engine.load(Self.asset(url), track: TrackRef(source: .local, id: "next"), autoplay: true)
        try await Self.waitUntil { engine.active.hasPreciseCopy }
        await engine.seek(to: 3)
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.spectrumSnapshot().overall < 0.05)
        #expect(server.served <= server.size + StubRangeProtocol.chunk, "served \(server.served) of \(server.size)")
    }

    @Test func cancelledArmingKeepsTheDownload() async throws {
        let current = try Self.silentFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: current) }
        let (url, server) = try StubRangeProtocol.register(Self.testFile())
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.volume = 0
        defer { engine.stop() }
        let wav = PlayableAsset(url: current, container: .wav, tier: QualityTier(.lossless), supportsTap: false, provider: .local)
        try await engine.load(wav, track: TrackRef(source: .local, id: "current"), autoplay: true)
        await engine.arm(next: Self.asset(url), track: TrackRef(source: .local, id: "next"))
        try await Self.waitUntil { server.served >= server.size }
        await engine.seek(to: 4)

        try await engine.load(Self.asset(url), track: TrackRef(source: .local, id: "next"), autoplay: true)
        try await Self.waitUntil { engine.active.hasPreciseCopy }
        #expect(server.served <= server.size + StubRangeProtocol.chunk, "served \(server.served) of \(server.size)")
    }

    /// Skipping a song whose download still waits for its first bytes: the player starts the
    /// next item (a request left waiting would hold it up for good).
    @Test func skippingAWaitingDownloadStartsTheNextItem() async throws {
        let next = try Self.silentFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: next) }
        let (url, _) = try StubRangeProtocol.register(Self.testFile(), bytesPerSecond: 1_000)
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.volume = 0
        defer { engine.stop() }
        try await engine.load(Self.asset(url), track: TrackRef(source: .local, id: "slow"), autoplay: true)
        try await Task.sleep(for: .milliseconds(300))
        let wav = PlayableAsset(url: next, container: .wav, tier: QualityTier(.lossless), supportsTap: true, provider: .local)
        try await engine.load(wav, track: TrackRef(source: .local, id: "next"), autoplay: true)
        try await Self.waitUntil { engine.currentTime > 0.5 }
    }

    /// A transcode (`isTranscode`): the server sends it as it makes it, without a length or byte
    /// ranges. It plays once it is all in, and seeks land where they report, FLAC or AAC.
    @Test(arguments: [AudioContainer.flac, .aac])
    func transcodePlaysOnceItIsIn(container: AudioContainer) async throws {
        let (url, server) = try StubRangeProtocol.register(Self.testFile(container), name: "stream.\(container.rawValue)", rangeless: true)
        let engine = AVDeckEngine(downloadConfiguration: StubRangeProtocol.configuration())
        engine.volume = 0
        defer { engine.stop() }
        var asset = PlayableAsset(url: url, container: container, tier: QualityTier(.lossless), supportsTap: true, provider: .source)
        asset.isTranscode = true
        try await engine.load(asset, track: TrackRef(source: .local, id: "transcode-\(container.rawValue)"), autoplay: true)
        try await Self.waitUntil { engine.active.isPlayingPreciseCopy }
        #expect(server.requests.count == 1 && server.served == server.size)
        #expect(engine.duration > 29.9 && engine.duration < 30.1, "duration \(engine.duration)")

        await engine.seek(to: 3)
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.spectrumSnapshot().overall < 0.05, "at 3 s: \(engine.spectrumSnapshot().overall)")
        await engine.seek(to: 25)
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.spectrumSnapshot().overall > 0.2, "at 25 s: \(engine.spectrumSnapshot().overall)")
    }

    @Test func localFileSeeksExactly() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "flac-\(UUID().uuidString).flac")
        try Self.testFile().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = AVDeckEngine()
        engine.volume = 0
        defer { engine.stop() }
        let asset = PlayableAsset(url: file, container: .flac, tier: QualityTier(.lossless), supportsTap: true, provider: .local)
        try await engine.load(asset, track: TrackRef(source: .local, id: "local"), autoplay: true)
        #expect(engine.active.isPlayingPreciseCopy)
        #expect(!engine.active.hasPreciseCopy)
        try await Self.waitUntil { engine.duration > 29.9 }
        await engine.seek(to: 3)
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.spectrumSnapshot().overall < 0.05, "at 3 s: \(engine.spectrumSnapshot().overall)")
    }

    @Test func loudnessScalesTheDeck() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "flac-\(UUID().uuidString).flac")
        try Self.testFile().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = AVDeckEngine()
        engine.volume = 0.5
        engine.loudness = Loudness(mode: .album)
        defer { engine.stop() }
        let asset = PlayableAsset(url: file, container: .flac, tier: QualityTier(.lossless), supportsTap: true, provider: .source, gain: ReplayGain(trackGain: -12, albumGain: -6))
        try await engine.load(asset, track: TrackRef(source: .local, id: "gain"), autoplay: false)
        #expect(abs(engine.active.player.volume - 0.5 * Float(pow(10, -6.0 / 20))) < 0.001)
        engine.loudness = Loudness(mode: .track)
        #expect(abs(engine.active.player.volume - 0.5 * Float(pow(10, -12.0 / 20))) < 0.001)
        engine.loudness = Loudness()
        #expect(engine.active.player.volume == 0.5)
    }

    private static func asset(_ url: URL) -> PlayableAsset {
        PlayableAsset(url: url, container: .flac, tier: QualityTier(.lossless), supportsTap: true, provider: .source)
    }

    /// 15 s of silence, then 15 s of noise; 16-bit stereo FLAC, or AAC in an ADTS stream (what a
    /// server's AAC transcode is).
    private static func testFile(_ container: AudioContainer = .flac) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "noise-src-\(UUID().uuidString).\(container.rawValue)")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        try {
            let settings: [String: Any] = container == .aac
                ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
                : [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(44_100)
            var generator = SystemRandomNumberGenerator()
            for second in 0..<30 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                buffer.frameLength = frames
                for channel in 0..<2 {
                    let samples = buffer.floatChannelData![channel]
                    for i in 0..<Int(frames) { samples[i] = second < 15 ? 0 : Float.random(in: -0.25...0.25, using: &generator) }
                }
                try file.write(from: buffer)
            }
        }()
        return try Data(contentsOf: url)
    }

    private static func surroundFile() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "surround-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_D)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        try {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 6,
                AVChannelLayoutKey: Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size),
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(48_000 * 3)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<6 {
                for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = 0.2 * sin(Float(frame) * 0.05 * Float(channel + 1)) }
            }
            try file.write(from: buffer)
        }()
        return try Data(contentsOf: url)
    }

    private static func silentFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deck-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    private static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

struct PositionScrambler: StreamDecryptor {
    func decrypt(_ bytes: UnsafeMutableRawBufferPointer, at offset: Int64) {
        for i in 0..<bytes.count { bytes[i] ^= UInt8(truncatingIfNeeded: (offset + Int64(i)) &* 31 &+ 7) }
    }
}

@MainActor final class FinishedFile {
    var url: URL?
}

final class StubRangeProtocol: URLProtocol, @unchecked Sendable {
    static let chunk = 64 * 1024

    final class Server: @unchecked Sendable {
        let data: Data
        let bytesPerSecond: Int?
        let rangeless: Bool
        private let lock = NSLock()
        private var sent = 0
        private var ranges: [String] = []
        var size: Int { data.count }
        var served: Int { lock.withLock { sent } }
        var requests: [String] { lock.withLock { ranges } }

        init(data: Data, bytesPerSecond: Int?, rangeless: Bool) {
            self.data = data
            self.bytesPerSecond = bytesPerSecond
            self.rangeless = rangeless
        }

        func record(request range: String) { lock.withLock { ranges.append(range) } }
        func record(sent count: Int) { lock.withLock { sent += count } }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: Server] = [:]

    static func register(_ data: Data, name: String = "song.flac", bytesPerSecond: Int? = nil, rangeless: Bool = false) throws -> (URL, Server) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        let server = Server(data: data, bytesPerSecond: bytesPerSecond, rangeless: rangeless)
        lock.withLock { servers[host] = server }
        return (URL(string: "http://\(host)/\(name)")!, server)
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubRangeProtocol.self]
        return configuration
    }

    private static func server(for request: URLRequest) -> Server? {
        guard let host = request.url?.host else { return nil }
        return lock.withLock { servers[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { server(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var timer: Timer?

    override func startLoading() {
        guard let server = Self.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let size = server.size
        var start = 0
        var end = size - 1
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        server.record(request: range)
        if range.hasPrefix("bytes="), !server.rangeless {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            start = Int(bounds[0]) ?? 0
            if bounds.count > 1, let last = Int(bounds[1]) { end = min(last, size - 1) }
        }
        let response = server.rangeless
            ? HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream", "Accept-Ranges": "none"])!
            : HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes \(start)-\(end)/\(size)", "Content-Length": "\(end - start + 1)", "Content-Type": "audio/flac"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var position = start
        let interval = server.bytesPerSecond.map { Double(Self.chunk) / Double($0) } ?? 0.001
        // Runs on this loading thread's run loop, where the client expects its calls.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let count = min(Self.chunk, end + 1 - position)
            self.client?.urlProtocol(self, didLoad: server.data.subdata(in: position..<position + count))
            server.record(sent: count)
            position += count
            if position > end {
                timer.invalidate()
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }

    override func stopLoading() {
        timer?.invalidate()
        timer = nil
    }
}
