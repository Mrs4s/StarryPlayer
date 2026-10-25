import AudioProcessing
import AVFoundation
import Foundation
import Observation
import PlaybackEngine
import StarryCore

/// Separate playback keeps lyric editing from changing the player's queue.
/// Uses decoded PCM for precise timing, falling back to streaming for unsupported files.
@MainActor @Observable
final class LyricsEditorAudio {
    enum Status: Equatable {
        case idle
        case loading(String)
        case ready
        case failed(String)
    }

    static let rates: [Double] = [0.5, 0.6, 0.75, 0.9, 1, 1.25, 1.5, 2]

    private(set) var track: Track?
    private(set) var status: Status = .idle
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Double = 1
    /// Slider position, 0…1 (`VolumeCurve`).
    private(set) var volume: Double = 0.8
    private(set) var waveform: WaveformPeaks?
    private(set) var vocals = VocalsStatus.none
    private(set) var onsets: [VocalOnset] = []
    private(set) var onsetStatus = OnsetStatus.none
    private(set) var duetStatus = DuetStatus.none
    private(set) var uncertainDuetOverlaps: [TimeInterval] = []
    private var duetHintsA: [VocalOnset] = []
    private var duetHintsB: [VocalOnset] = []
    private var duetHintsAll: [VocalOnset] = []

    enum HintVoice: String, CaseIterable {
        case all, a, b
        var title: String {
            switch self {
            case .all: "全部"
            case .a: "人声 A"
            case .b: "人声 B"
            }
        }
    }

    enum DuetStatus: Equatable {
        case none, separating(Double), analyzing, ready
        case failed(String)
        var isWorking: Bool {
            switch self {
            case .separating, .analyzing: true
            default: false
            }
        }
    }

    struct DuetRequest: Sendable {
        var input: URL
        var first: URL
        var second: URL
        var model: URL
        var progress: @Sendable (Double) -> Void
    }
    typealias DuetWork = @Sendable (DuetRequest) async throws -> VocalDuetSeparation

    enum OnsetStatus: Equatable {
        case none, analyzing, ready
        case failed(String)
    }

    enum VocalsStatus: Equatable {
        case none
        /// Separating, this far through (0…1).
        case separating(Double)
        case ready
        case failed(String)
    }

    @ObservationIgnored var vocalModel: VocalSeparationModel = .systemVoice {
        didSet { if vocalModel != oldValue, vocals != .none { discardVocals() } }
    }

    @ObservationIgnored var resolve: ((Track) async throws -> PlayableAsset)?
    /// Runs before playback starts: the player pauses, so two songs never play over each other.
    @ObservationIgnored var willPlay: (() -> Void)?

    private enum Backend {
        case none
        case pcm(PCMPlayer, file: URL)
        case stream
    }

    @ObservationIgnored private var backend = Backend.none
    /// Streams what cannot be decoded, and downloads remote songs for decoding.
    @ObservationIgnored private let engine = AVDeckEngine()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The download being waited for, to decode once it is in.
    @ObservationIgnored private var awaitingDownload: Int?
    @ObservationIgnored private var outputDeviceUID: String?
    @ObservationIgnored private var vocalsFile: URL?
    @ObservationIgnored private var vocalsTask: Task<Void, Never>?
    @ObservationIgnored private var vocalRequestID = UUID()
    @ObservationIgnored private var onsetTask: Task<Void, Never>?
    @ObservationIgnored private var onsetRequestID = UUID()
    @ObservationIgnored private var duetTask: Task<Void, Never>?
    @ObservationIgnored private var duetRequestID = UUID()
    @ObservationIgnored private var duetFiles: VocalDuetSeparation?
    @ObservationIgnored private let duetWork: DuetWork
    @ObservationIgnored private let duetSeparator: VocalDuetSeparator?

    init(duetWork: DuetWork? = nil) {
        let separator = VocalDuetSeparator()
        self.duetSeparator = duetWork == nil ? separator : nil
        self.duetWork = duetWork ?? { request in
            try await separator.separate(file: request.input, first: request.first, second: request.second,
                                         model: request.model, progress: request.progress)
        }
        engine.keepsDownloads = true
        engine.volume = VolumeCurve.gain(forLevel: volume)
        // Decoded songs left by an earlier run.
        try? FileManager.default.removeItem(at: PCMPlayer.directory)
        let events = engine.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    var isReady: Bool { status == .ready }

    var isPrecise: Bool {
        if case .pcm = backend { return true }
        return false
    }

    func clock() -> (time: TimeInterval, rate: Double) {
        switch backend {
        case .pcm(let player, _): (player.currentTime, player.isPlaying ? Double(player.rate) : 0)
        case .stream: (engine.currentTime, Double(engine.rate))
        case .none: (0, 0)
        }
    }

    var currentTime: TimeInterval { clock().time }

    // MARK: Vocals

    func prepareVocals() {
        guard case .pcm(_, let song) = backend else { return }
        switch vocals {
        case .none, .failed: break
        case .separating, .ready: return
        }
        let id = generation
        let requestID = UUID()
        vocalRequestID = requestID
        let destination = PCMPlayer.directory.appendingPathComponent("\(UUID().uuidString)-vocals.caf")
        let model = vocalModel
        vocals = .separating(0)
        let report: @Sendable (Double) -> Void = { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in
                guard id == self.generation, requestID == self.vocalRequestID, case .separating = self.vocals else { return }
                self.vocals = .separating(progress)
            }
        }
        vocalsTask = Task { [weak self] in
            do {
                try await VocalExtraction.extractVocals(from: song, to: destination, model: model, progress: report)
                guard let self, id == self.generation, requestID == self.vocalRequestID, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: destination)
                    return
                }
                self.vocalsFile = destination
                self.vocals = .ready
            } catch {
                try? FileManager.default.removeItem(at: destination)
                guard let self, id == self.generation, requestID == self.vocalRequestID, !(error is CancellationError) else { return }
                self.vocals = .failed(error as? VocalExtraction.Failure == .unsupported ? "这台 Mac 没有能处理这首歌的人声分离模型" : "人声分离没能完成")
            }
        }
    }

    func discardVocals() {
        discardDuet()
        vocalRequestID = UUID()
        vocalsTask?.cancel()
        vocalsTask = nil
        if let vocalsFile { try? FileManager.default.removeItem(at: vocalsFile) }
        vocalsFile = nil
        vocals = .none
        cancelOnsets()
        onsets = []
        onsetStatus = .none
    }

    // MARK: Onset hints

    /// Hints always use isolated vocals, even when the displayed spectrum is the mix.
    func prepareOnsets() {
        guard isPrecise else { return }
        guard vocals == .ready, let vocalsFile else {
            prepareVocals()
            return
        }
        guard onsetStatus != .analyzing, onsetStatus != .ready else { return }
        let requestID = UUID()
        onsetRequestID = requestID
        onsetStatus = .analyzing
        onsetTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { try VocalOnsetDetector.analyze(file: vocalsFile) }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, self.onsetRequestID == requestID, !Task.isCancelled else { return }
                self.onsets = result
                self.onsetStatus = .ready
                self.onsetTask = nil
            } catch {
                guard let self, self.onsetRequestID == requestID, !Task.isCancelled else { return }
                self.onsetStatus = .failed("起字提示分析没能完成，请重试")
                self.onsetTask = nil
            }
        }
    }

    /// Keep completed results so toggling hints does not repeat the analysis.
    func cancelOnsets() {
        onsetRequestID = UUID()
        onsetTask?.cancel()
        onsetTask = nil
        if onsetStatus == .analyzing { onsetStatus = .none }
    }

    // MARK: Separate-voice hints

    func duetOnsets(for voice: HintVoice) -> [VocalOnset] {
        guard duetStatus == .ready else { return [] }
        switch voice {
        case .all: return duetHintsAll
        case .a: return duetHintsA
        case .b: return duetHintsB
        }
    }

    func prepareDuetOnsets() {
        guard isPrecise, !duetStatus.isWorking, duetStatus != .ready else { return }
        guard vocals == .ready, let vocalsFile else {
            prepareVocals()
            return
        }
        guard let model = VocalDuetSeparator.bundledModel(in: .main) else {
            duetStatus = .failed("未找到内置的分轨模型")
            return
        }
        let requestID = UUID()
        duetRequestID = requestID
        let first = PCMPlayer.directory.appendingPathComponent("\(requestID)-voice-a.caf")
        let second = PCMPlayer.directory.appendingPathComponent("\(requestID)-voice-b.caf")
        duetStatus = .separating(0)
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.duetRequestID == requestID, self.duetStatus.isWorking else { return }
                if case .separating = self.duetStatus { self.duetStatus = .separating(value) }
            }
        }
        let work = duetWork
        let separator = duetSeparator
        duetTask = Task { [weak self] in
            var keepFiles = false
            defer {
                if !keepFiles {
                    try? FileManager.default.removeItem(at: first)
                    try? FileManager.default.removeItem(at: second)
                }
            }
            do {
                let result = try await work(DuetRequest(input: vocalsFile, first: first, second: second, model: model, progress: report))
                if let separator { await separator.releaseResources() }
                try Task.checkCancellation()
                guard let self, self.duetRequestID == requestID else { return }
                self.duetStatus = .analyzing
                let worker = Task.detached(priority: .utility) {
                    let a = try VocalOnsetDetector.analyze(file: result.first)
                    let b = try VocalOnsetDetector.analyze(file: result.second)
                    return (a, b)
                }
                let (a, b) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard self.duetRequestID == requestID else { return }
                self.duetHintsA = a
                self.duetHintsB = b
                self.duetHintsAll = Self.combinedHints(a, b)
                self.duetFiles = result
                self.uncertainDuetOverlaps = result.uncertainOverlaps
                self.duetStatus = .ready
                self.duetTask = nil
                keepFiles = true
            } catch {
                if let separator { await separator.releaseResources() }
                guard let self, self.duetRequestID == requestID, !Task.isCancelled else { return }
                self.duetStatus = .failed("分轨起字分析没能完成，可在提示设置中重试")
                self.duetTask = nil
            }
        }
    }

    func cancelDuetOnsets() {
        duetRequestID = UUID()
        duetTask?.cancel()
        duetTask = nil
        if duetStatus.isWorking { duetStatus = .none }
        if let duetSeparator { Task { await duetSeparator.releaseResources() } }
    }

    private func discardDuet() {
        cancelDuetOnsets()
        if let duetFiles {
            try? FileManager.default.removeItem(at: duetFiles.first)
            try? FileManager.default.removeItem(at: duetFiles.second)
        }
        duetFiles = nil
        duetHintsA = []; duetHintsB = []; duetHintsAll = []
        uncertainDuetOverlaps = []
        duetStatus = .none
    }

    /// Preserve close, distinct events from different voices. Only merge candidates
    /// on effectively the same 10 ms analysis frame, keeping the stronger hint.
    static func combinedHints(_ a: [VocalOnset], _ b: [VocalOnset]) -> [VocalOnset] {
        var result: [VocalOnset] = []
        for hint in (a + b).sorted(by: { $0.time < $1.time }) {
            if let last = result.last, abs(last.time - hint.time) < 0.005 {
                if hint.strength > last.strength { result[result.count - 1] = hint }
            } else { result.append(hint) }
        }
        return result
    }

    // MARK: Spectrogram

    /// Renders off the main thread; nil until decoded. Uses the full mix until vocals are ready.
    func spectrogram(of range: ClosedRange<TimeInterval>, width: Int, height: Int, gain: Float, vocalsOnly: Bool = false, voice: HintVoice = .all) async -> CGImage? {
        guard case .pcm(_, let song) = backend, width > 0, height > 0 else { return nil }
        var file = vocalsOnly && vocals == .ready ? vocalsFile ?? song : song
        if vocalsOnly, duetStatus == .ready, let duetFiles {
            if voice == .a { file = duetFiles.first }
            if voice == .b { file = duetFiles.second }
        }
        let source = file
        let render = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            guard let (samples, rate) = Self.monoSamples(of: source, around: range) else { return nil }
            return Spectrogram.image(samples: samples, sampleRate: rate, width: width, height: height, gain: gain)
        }
        return await withTaskCancellationHandler {
            await render.value
        } onCancel: {
            render.cancel()
        }
    }

    /// The decoded song's channels mixed down over `range`, from half an FFT before it to half
    /// one after (so each column's frame is centred on its time), silence outside the song.
    private nonisolated static func monoSamples(of url: URL, around range: ClosedRange<TimeInterval>) -> ([Float], Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let first = Int((range.lowerBound * rate).rounded()) - Spectrogram.fftSize / 2
        let count = Int(((range.upperBound - range.lowerBound) * rate).rounded()) + Spectrogram.fftSize
        var samples = [Float](repeating: 0, count: count)
        let readStart = max(first, 0)
        let lead = readStart - first
        let toRead = min(count - lead, Int(file.length) - readStart)
        guard toRead > 0 else { return (samples, rate) }
        file.framePosition = AVAudioFramePosition(readStart)
        let block = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)) else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        var filled = 0
        // A read can return less than asked: read until the span is in.
        while filled < toRead {
            guard !Task.isCancelled else { return nil }
            guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(min(block, toRead - filled)))) != nil,
                  buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            samples.withUnsafeMutableBufferPointer { out in
                for channel in 0..<channelCount {
                    for i in 0..<frames { out[lead + filled + i] += channels[channel][i] / Float(channelCount) }
                }
            }
            filled += frames
        }
        return (samples, rate)
    }

    // MARK: Loading

    func load(_ track: Track, volume: Double? = nil) {
        if let volume { setVolume(volume) }
        if self.track?.id == track.id, status == .ready || status.isLoading { return }
        stop()
        generation += 1
        let id = generation
        self.track = track
        status = .loading("正在载入「\(track.title)」的音频…")
        duration = track.duration
        loadTask = Task { [weak self] in
            guard let self, let resolve = self.resolve else { return }
            do {
                let asset = try await resolve(track)
                guard id == self.generation, !Task.isCancelled else { return }
                if asset.url.isFileURL {
                    if await self.decode(asset.url, id: id) { return }
                    guard id == self.generation else { return }
                } else if Self.downloadsWhole(asset) {
                    // The engine downloads it whole (unscrambled); `handle` decodes it once it is in.
                    self.awaitingDownload = id
                    self.status = .loading("正在下载「\(track.title)」…")
                    try await self.engine.load(asset, track: track.id, autoplay: false, startAt: nil)
                    return
                }
                try await self.engine.load(asset, track: track.id, autoplay: false, startAt: nil)
                guard id == self.generation else { return }
                self.useStream()
            } catch {
                guard id == self.generation else { return }
                self.status = .failed(Self.message(for: error))
            }
        }
    }

    private func decode(_ file: URL, id: Int) async -> Bool {
        status = .loading("正在解码音频…")
        let pcm = PCMPlayer.directory.appendingPathComponent("\(UUID().uuidString).caf")
        do {
            let peaks = try await PCMPlayer.decode(file, to: pcm)
            guard id == generation else {
                try? FileManager.default.removeItem(at: pcm)
                return true
            }
            let player = try PCMPlayer(file: pcm)
            player.volume = VolumeCurve.gain(forLevel: volume)
            player.setRate(Float(rate))
            if outputDeviceUID != nil { player.setOutputDevice(uid: outputDeviceUID) }
            player.onEnded = { [weak self] in self?.isPlaying = false }
            engine.stop()
            backend = .pcm(player, file: pcm)
            waveform = peaks
            if player.duration > 0 { duration = player.duration }
            status = .ready
            return true
        } catch {
            try? FileManager.default.removeItem(at: pcm)
            return false
        }
    }

    private func useStream() {
        backend = .stream
        engine.playbackRate = Float(rate)
        status = .ready
    }

    func stop() {
        loadTask?.cancel()
        discardVocals()
        generation += 1
        awaitingDownload = nil
        if case .pcm(let player, let file) = backend {
            player.close()
            try? FileManager.default.removeItem(at: file)
        }
        if track != nil { engine.stop() }
        backend = .none
        track = nil
        status = .idle
        isPlaying = false
        waveform = nil
    }

    func retry() {
        guard let track else { return }
        self.track = nil
        load(track)
    }

    /// Remote files the engine downloads whole when it keeps downloads; the rest it streams.
    private static func downloadsWhole(_ asset: PlayableAsset) -> Bool {
        asset.decryption != nil || asset.container == .flac || asset.container == .ogg || asset.isTranscode
            || (asset.container != .hls && !asset.isTrial && asset.range == nil)
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .downloadFinished(let ref, let file):
            guard ref == track?.id, let id = awaitingDownload, id == generation else { return }
            awaitingDownload = nil
            Task {
                if await decode(file, id: id) { return }
                guard id == generation else { return }
                // Downloaded but not decodable (Ogg): the engine has it loaded already.
                useStream()
            }
        case .rate(let rate):
            if case .stream = backend { isPlaying = rate > 0 }
        case .duration(let duration):
            if case .stream = backend, duration > 0, (track?.duration ?? 0) <= 0 { self.duration = duration }
        case .playbackEnded:
            if case .stream = backend { isPlaying = false }
        case .error(let error):
            if case .pcm = backend { return }
            if status == .ready || status.isLoading {
                isPlaying = false
                status = .failed(Self.message(for: error))
            }
        default:
            break
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? PlaybackError {
        case .vipRequired: "这首歌需要会员才能播放"
        case .sourceUnreachable: "找不到这首歌的音频"
        case .decodeFailed: "这首歌的音频没能解码"
        default: "没能载入这首歌：\(error.localizedDescription)"
        }
    }

    // MARK: Transport

    func play() {
        guard isReady else { return }
        willPlay?()
        switch backend {
        case .pcm(let player, _):
            player.play()
        case .stream:
            if duration > 0, engine.currentTime >= duration - 0.05 { Task { await engine.seek(to: 0) } }
            engine.play()
        case .none:
            return
        }
        isPlaying = true
    }

    /// Stops where it is at once: no fade, so what was heard last is where it stopped.
    func pause() {
        guard isReady, isPlaying else { return }
        switch backend {
        case .pcm(let player, _): player.pause()
        case .stream: engine.pause(fade: false)
        case .none: break
        }
        isPlaying = false
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to time: TimeInterval) {
        guard isReady else { return }
        let end = duration > 0 ? duration : .infinity
        let target = min(max(0, time), end)
        switch backend {
        case .pcm(let player, _): player.seek(to: target)
        case .stream: Task { await engine.seek(to: target) }
        case .none: break
        }
    }

    func seek(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    func play(from time: TimeInterval) {
        seek(to: time)
        if !isPlaying { play() }
    }

    func setRate(_ rate: Double) {
        let rate = min(max(rate, Self.rates.first!), Self.rates.last!)
        self.rate = rate
        engine.playbackRate = Float(rate)
        if case .pcm(let player, _) = backend { player.setRate(Float(rate)) }
    }

    func stepRate(_ step: Int) {
        let index = Self.rates.firstIndex { $0 >= rate - 0.001 } ?? Self.rates.count - 1
        setRate(Self.rates[min(max(index + step, 0), Self.rates.count - 1)])
    }

    func setVolume(_ level: Double) {
        volume = min(max(level, 0), 1)
        let gain = VolumeCurve.gain(forLevel: volume)
        engine.volume = gain
        if case .pcm(let player, _) = backend { player.volume = gain }
    }

    func setOutputDevice(_ uid: String?) {
        outputDeviceUID = uid
        engine.outputDeviceUID = uid
        if case .pcm(let player, _) = backend { player.setOutputDevice(uid: uid) }
    }
}

extension LyricsEditorAudio.Status {
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
