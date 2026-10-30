import AudioProcessing
import AudioToolbox
import AVFoundation
import Foundation

/// Plays decoded audio with a clock corrected for output latency.
/// Small output buffers reduce start delay. At normal speed the time stretcher is removed
/// from the signal path because bypassing it still adds latency.
@MainActor
public final class PCMPlayer {
    public let duration: TimeInterval
    public private(set) var isPlaying = false
    public private(set) var rate: Float = 1
    public var volume: Float = 1 {
        didSet { player.volume = volume }
    }
    public var onEnded: (() -> Void)?

    private let file: AVAudioFile
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let sampleRate: Double
    private let format: AVAudioFormat
    private var stretching = false
    private static let ioBufferFrames: UInt32 = 128
    /// Where the scheduled segment starts, in seconds.
    private var startTime: TimeInterval = 0
    private var scheduled = false
    private var generation = 0
    private var clock = HeardClock()
    private var outputDeviceUID: String?
    private var configurationObserver: NSObjectProtocol?

    /// Opens a file `decode` wrote and starts the engine, so playing needs nothing more.
    public init(file url: URL) throws {
        file = try AVAudioFile(forReading: url)
        format = file.processingFormat
        sampleRate = format.sampleRate
        duration = Double(file.length) / sampleRate
        engine.attach(player)
        engine.attach(timePitch)
        wire()
        useSmallBuffers()
        engine.prepare()
        try engine.start()
        schedule(from: 0)
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromConfigurationChange() }
        }
    }

    public func close() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        generation += 1
        player.stop()
        engine.stop()
        isPlaying = false
    }

    // MARK: Clock

    /// The position heard now: the player's rendered frames, the time since that render, less
    /// what is still on its way to the speaker. Never runs backwards between seeks.
    public var currentTime: TimeInterval {
        guard isPlaying, let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid, let playerTime = player.playerTime(forNodeTime: nodeTime) else { return startTime }
        var time = startTime + Double(playerTime.sampleTime) / playerTime.sampleRate
        if nodeTime.isHostTimeValid {
            let elapsed = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: nodeTime.hostTime)
            time += min(max(elapsed, 0), 0.1) * Double(rate)
        }
        time -= outputLatency * Double(rate)
        return min(clock.time(raw: max(time, startTime), latency: 0), duration)
    }

    var outputLatency: TimeInterval {
        engine.outputNode.presentationLatency + (stretching ? timePitch.auAudioUnit.latency : 0)
    }

    private func wire() {
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        if stretching {
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }

    /// Asks the output for `ioBufferFrames`: the device runs at the smallest any app asks for,
    /// and returns to its own once the engine stops.
    private func useSmallBuffers() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var frames = Self.ioBufferFrames
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
    }

    // MARK: Transport

    /// Plays at `rate` from now on, the pitch kept. The clock carries on from where the old speed
    /// left it.
    public func setRate(_ rate: Float) {
        guard rate != self.rate else { return }
        let time = currentTime
        self.rate = rate
        timePitch.rate = rate
        let playing = isPlaying
        player.stop()
        if stretching != (rate != 1) {
            stretching = rate != 1
            wire()
        }
        if playing {
            restart(at: time)
        } else {
            rest(at: time)
        }
    }

    public func play() {
        guard !isPlaying else { return }
        if startTime >= duration - 0.001 { seek(to: 0) }
        if !engine.isRunning { try? engine.start() }
        if !scheduled { schedule(from: startTime) }
        clock.reset(to: startTime)
        player.play()
        isPlaying = true
    }

    public func pause() {
        guard isPlaying else { return }
        let time = currentTime
        isPlaying = false
        rest(at: time)
    }

    public func seek(to time: TimeInterval) {
        let time = min(max(time, 0), duration)
        if isPlaying {
            restart(at: time)
        } else {
            rest(at: time)
        }
    }

    private func restart(at time: TimeInterval) {
        player.stop()
        schedule(from: time)
        clock.reset(to: time)
        player.play()
    }

    private func rest(at time: TimeInterval) {
        player.stop()
        schedule(from: time)
        clock.reset(to: time)
    }

    private func schedule(from time: TimeInterval) {
        generation += 1
        let id = generation
        startTime = time
        let frame = min(AVAudioFramePosition((time * sampleRate).rounded()), file.length)
        let remaining = file.length - frame
        scheduled = true
        guard remaining > 0 else { return }
        player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.segmentEnded(id) }
        }
        player.prepare(withFrameCount: AVAudioFrameCount(min(remaining, AVAudioFramePosition(sampleRate / 2))))
    }

    /// The segment played out (a stop also calls back: the generation tells them apart).
    private func segmentEnded(_ id: Int) {
        guard id == generation, isPlaying else { return }
        isPlaying = false
        rest(at: duration)
        onEnded?()
    }

    // MARK: Output

    /// Plays through the output with `uid`; nil follows the system output.
    public func setOutputDevice(uid: String?) {
        guard uid != outputDeviceUID else { return }
        outputDeviceUID = uid
        let time = currentTime
        let wasPlaying = isPlaying
        player.stop()
        engine.stop()
        var device = uid.flatMap(AudioOutputDevices.deviceID(forUID:)) ?? AudioOutputDevices.defaultOutputID()
        if let unit = engine.outputNode.audioUnit, device != 0 {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        useSmallBuffers()
        resume(at: time, playing: wasPlaying)
    }

    /// The output changed under the engine (a device plugged in or out): it stopped, so it
    /// starts again where it was.
    private func recoverFromConfigurationChange() {
        resume(at: currentTime, playing: isPlaying)
    }

    private func resume(at time: TimeInterval, playing: Bool) {
        isPlaying = false
        useSmallBuffers()
        engine.prepare()
        try? engine.start()
        rest(at: time)
        if playing { play() }
    }

    // MARK: Decoding

    /// Decodes `source` (anything AVAudioFile opens: MP3, AAC, ALAC, FLAC, WAV, AIFF) whole into
    /// a float file at `destination`, measuring its waveform on the way, off the main thread.
    /// The file's own priming and padding are left out, as AVPlayer leaves them out.
    public nonisolated static func decode(_ source: URL, to destination: URL) async throws -> WaveformPeaks {
        try await Task.detached(priority: .userInitiated) {
            let input = try AVAudioFile(forReading: source)
            let format = input.processingFormat
            try? FileManager.default.removeItem(at: destination)
            let output = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(64 * 1024)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw CocoaError(.fileReadCorruptFile) }
            var peaks = WaveformPeaks.Accumulator(sampleRate: format.sampleRate, expectedFrames: input.length)
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: frames)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                peaks.add(buffer)
            }
            guard output.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
            return peaks.finish()
        }.value
    }

    public nonisolated static var directory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StarryPCM", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
