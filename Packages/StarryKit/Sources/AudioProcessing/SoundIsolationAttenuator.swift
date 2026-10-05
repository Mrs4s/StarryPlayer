import AudioToolbox
import Foundation
import os

/// What every item's attenuator follows. Written on the main thread, read at the start of each
/// audio block under an unfair lock (uncontended, no allocation).
public final class VocalAttenuationControl: Sendable {
    public struct State: Sendable, Equatable {
        public var enabled = false
        /// Slider value on `VocalAttenuationCurve`'s 5…100 scale; each unit turns it into a voice
        /// gain for the model it runs.
        public var vocalLevel = VocalAttenuationCurve.defaultLevel
        public var suspended = false
        /// Network used by units built from now on.
        public var model: VocalSeparationModel = .systemVoice
        public init() {}
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var current: State { state.withLock { $0 } }

    public func update(_ body: @Sendable (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    /// The fields the audio thread needs, without copying the model's URLs and strings.
    func audioState() -> (wanted: Bool, vocalLevel: Double) {
        state.withLock { ($0.enabled && !$0.suspended, $0.vocalLevel) }
    }
}

public final class SoundIsolationAttenuator: AudioProcessor, @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        public var isProcessing = false
        public var latencyFrames = 0
        public var sampleRate: Double = 0
        /// Network in use (after fallbacks); nil until a unit exists.
        public var model: VocalSeparationModel?
        /// A unit is being built.
        public var isPreparing = false
        public var failedPerformance = false
        /// More than two channels, or no network accepts the source.
        public var unsupportedFormat = false
        /// Times a jump in the source position (a seek) reset the unit.
        public var seekResets = 0

        /// Time the output trails the source by (0 when not processing).
        public var latency: TimeInterval {
            isProcessing && sampleRate > 0 ? Double(latencyFrames) / sampleRate : 0
        }

        public init() {}
    }

    public var isEnabled = true
    public var latencyFrames: Int { statusLock.withLock { $0.isProcessing ? $0.latencyFrames : 0 } }
    public var status: Status { statusLock.withLock { $0 } }
    public var latency: TimeInterval { statusLock.withLock { $0.latency } }

    public var fadeOutDuration: TimeInterval = 0.15
    public var fadeInDuration: TimeInterval = 0.1

    private let control: VocalAttenuationControl
    private let onStatusChange: (@Sendable () -> Void)?
    private let statusLock = OSAllocatedUnfairLock(initialState: Status())
    private let builtUnit = OSAllocatedUnfairLock<IsolationUnit?>(uncheckedState: nil)
    private let buildQueue = DispatchQueue(label: "starry.vocal-attenuation.build", qos: .userInitiated)

    // Written during prepare, before processing starts; read-only afterwards.
    private var format: ProcessingFormat?
    private var feed: InputFeed?

    // Audio thread only.
    private var unit: IsolationUnit?
    private var processing = false
    private var switchPending = false
    private var hasOutput = false
    private var expectedIndex: Int64?
    private var lastIndex: Int64?
    private var appliedLevel = Double.nan
    private var envelope = GainEnvelope()
    private var overruns = OverrunCounter()
    private var failed = false
    private var renderTime: Float64 = 0

    public init(control: VocalAttenuationControl, onStatusChange: (@Sendable () -> Void)? = nil) {
        self.control = control
        self.onStatusChange = onStatusChange
    }

    public func prepare(format: ProcessingFormat) {
        self.format = format
        feed = InputFeed(channels: format.channelCount, maxFrames: format.maxFrames)
        builtUnit.withLockUnchecked { $0 = nil }
        unit = nil
        processing = false
        switchPending = false
        hasOutput = false
        expectedIndex = nil
        lastIndex = nil
        appliedLevel = .nan
        envelope = GainEnvelope()
        overruns.reset()
        failed = false
        renderTime = 0
        let unsupported = !(1...2).contains(format.channelCount)
        updateStatus {
            $0 = Status()
            $0.sampleRate = format.sampleRate
            $0.unsupportedFormat = unsupported
        }
        // Already on: build now so the item starts processed (the tap waits for `prepare`).
        if control.audioState().wanted, !unsupported {
            installUnit(Self.makeUnit(format: format, control: control, feed: feed!))
        }
    }

    public func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        process(buffers, frameCount: frameCount, sampleIndex: nil)
    }

    public func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, sampleIndex: Int64?) {
        guard let format, let feed, frameCount > 0, frameCount <= format.maxFrames, buffers.count == format.channelCount else { return }
        if unit == nil { unit = builtUnit.withLockUnchecked { $0 } }

        // A seek: the unit still holds audio from before it. AVPlayer hands the same position
        // again right after a seek (preroll) and repeatedly at the end of the item; an exact
        // repeat is not a new jump.
        let jumped: Bool
        if let sampleIndex, let expectedIndex, sampleIndex != lastIndex {
            jumped = abs(sampleIndex - expectedIndex) > 16
        } else {
            jumped = false
        }
        if let sampleIndex {
            expectedIndex = sampleIndex + Int64(frameCount)
            lastIndex = sampleIndex
        }

        let state = control.audioState()
        let wanted = state.wanted && !failed && unit != nil
        if wanted != processing {
            if !hasOutput || jumped {
                switchPending = false
                setProcessing(wanted, faded: true)
            } else if !switchPending || !envelope.isFadingOut {
                switchPending = true
                envelope.fade(to: 0, over: frames(fadeOutDuration))
            }
        } else {
            if switchPending {
                switchPending = false                       // flipped back before the fade ended
                envelope.fade(to: 1, over: frames(fadeInDuration))
            }
            if jumped, processing, let unit {
                AudioUnitReset(unit.unit, kAudioUnitScope_Global, 0)
                envelope.mute(frames: unit.latencyFrames, thenFadeInOver: frames(fadeInDuration))
                updateStatus { $0.seekResets += 1 }
            }
        }
        if switchPending, envelope.isSilent {
            switchPending = false
            setProcessing(wanted, faded: true)
        }

        if processing, let unit {
            if state.vocalLevel != appliedLevel {
                let gain = VocalAttenuationCurve.gain(forSlider: state.vocalLevel, residual: unit.residual)
                let percent = VocalAttenuationCurve.wetDryPercent(voiceGain: gain, isolates: unit.output)
                AudioUnitSetParameter(unit.unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, percent, 0)
                appliedLevel = state.vocalLevel
            }
            render(buffers, frameCount: frameCount, unit: unit, feed: feed, sampleRate: format.sampleRate)
        }
        envelope.apply(buffers, frameCount: frameCount)
        hasOutput = true
    }

    public func reset() {
        expectedIndex = nil
        lastIndex = nil
    }

    /// The tap delivers a format the chain cannot process (not Float32 non-interleaved).
    public func markUnsupported(sampleRate: Double) {
        format = nil
        updateStatus {
            $0 = Status()
            $0.sampleRate = sampleRate
            $0.unsupportedFormat = true
        }
    }

    /// Builds the unit in the background if the switch is on and none exists yet.
    public func prepareUnitIfNeeded() {
        guard control.audioState().wanted, let format, let feed else { return }
        let start = statusLock.withLock { status -> Bool in
            guard status.model == nil, !status.isPreparing, !status.unsupportedFormat else { return false }
            status.isPreparing = true
            return true
        }
        guard start else { return }
        notifyStatusChange()
        let control = control
        buildQueue.async { [weak self] in
            let unit = Self.makeUnit(format: format, control: control, feed: feed)
            self?.installUnit(unit)
        }
    }

    private func frames(_ seconds: TimeInterval) -> Int {
        Int((seconds * (format?.sampleRate ?? 44100)).rounded())
    }

    private func setProcessing(_ on: Bool, faded: Bool) {
        processing = on
        if on, let unit {
            AudioUnitReset(unit.unit, kAudioUnitScope_Global, 0)
            appliedLevel = .nan
            // The unit outputs silence until primed; then the music continues where it stopped.
            envelope.mute(frames: unit.latencyFrames, thenFadeInOver: frames(fadeInDuration))
        } else if faded {
            envelope.fade(to: 1, over: frames(fadeInDuration))
        }
        updateStatus { $0.isProcessing = on }
    }

    private func render(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, unit: IsolationUnit, feed: InputFeed, sampleRate: Double) {
        for channel in 0..<buffers.count {
            guard let source = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            (feed.samples + channel * feed.maxFrames).update(from: source, count: frameCount)
        }
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = renderTime
        timestamp.mFlags = .sampleTimeValid
        renderTime += Float64(frameCount)
        let started = DispatchTime.now().uptimeNanoseconds
        let status = AudioUnitRender(unit.unit, &flags, &timestamp, 0, UInt32(frameCount), buffers.unsafeMutablePointer)
        let finished = DispatchTime.now().uptimeNanoseconds
        if status != noErr {
            for channel in 0..<buffers.count {
                buffers[channel].mData?.assumingMemoryBound(to: Float.self).update(from: feed.samples + channel * feed.maxFrames, count: frameCount)
            }
        }
        let elapsed = Double(finished - started) / 1e9
        if status != noErr || overruns.record(blockDuration: Double(frameCount) / sampleRate, elapsed: elapsed, now: Double(finished) / 1e9) {
            if !failed {
                failed = true
                updateStatus { $0.failedPerformance = true }
            }
        }
    }

    private func installUnit(_ unit: IsolationUnit?) {
        builtUnit.withLockUnchecked { $0 = unit }
        updateStatus {
            $0.isPreparing = false
            $0.model = unit?.model
            $0.latencyFrames = unit?.latencyFrames ?? 0
            if unit == nil { $0.unsupportedFormat = true }
        }
    }

    private func updateStatus(_ body: (inout Status) -> Void) {
        let changed = statusLock.withLockUnchecked { status -> Bool in
            let before = status
            body(&status)
            return status != before
        }
        if changed { notifyStatusChange() }
    }

    private func notifyStatusChange() {
        guard let onStatusChange else { return }
        DispatchQueue.main.async(execute: onStatusChange)
    }

    private static func makeUnit(format: ProcessingFormat, control: VocalAttenuationControl, feed: InputFeed) -> IsolationUnit? {
        let model = control.current.model
        if model.accepts(channelCount: format.channelCount), let unit = IsolationUnit(format: format, model: model, feed: feed) {
            return unit
        }
        guard model != .systemVoice, VocalSeparationModel.systemVoice.accepts(channelCount: format.channelCount) else { return nil }
        NSLog("[vocal] %@ cannot process %d ch; using the system voice model", model.name, format.channelCount)
        return IsolationUnit(format: format, model: .systemVoice, feed: feed)
    }
}

private enum IsolationProperty {
    static let modelPlistPath: AudioUnitPropertyID = 30000
    static let modelBasePath: AudioUnitPropertyID = 40000
    static let dereverbPreset: AudioUnitPropertyID = 50000
}

final class IsolationUnit: @unchecked Sendable {
    let unit: AudioUnit
    let model: VocalSeparationModel
    /// Copies of the model's fields the audio thread reads.
    let output: VocalSeparationModel.Output
    let residual: VocalResidual?
    let latencyFrames: Int
    let feed: InputFeed

    /// Initialise only after callbacks, formats and model paths are set, or latency is incorrect.
    init?(format: ProcessingFormat, model: VocalSeparationModel, feed: InputFeed) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { return nil }
        self.unit = unit
        self.model = model
        self.output = model.output
        self.residual = model.residual
        self.feed = feed

        var ok = true
        func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ value: T, required: Bool = true) {
            let status = withUnsafePointer(to: value) { AudioUnitSetProperty(unit, property, scope, 0, $0, UInt32(MemoryLayout<T>.size)) }
            if status != noErr {
                NSLog("[vocal] AUSoundIsolation property %u failed: %d", property, status)
                if required { ok = false }
            }
        }
        let callback = AURenderCallbackStruct(inputProc: feedRenderCallback, inputProcRefCon: Unmanaged.passUnretained(feed).toOpaque())
        set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, callback)
        set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, UInt32(format.maxFrames))
        let asbd = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(format.channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, asbd)
        set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, asbd)
        switch model.source {
        case .directory(let directory, let plist):
            let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
            set(IsolationProperty.modelPlistPath, kAudioUnitScope_Global, plist.path as CFString)
            set(IsolationProperty.modelBasePath, kAudioUnitScope_Global, base as CFString)
        case .systemVoice:
            // Only the high-quality model's output lines up with the dry path, which the
            // subtraction needs; the standard voice model (all macOS 14 has) is 1595 frames off.
            if #available(macOS 15, *) {
                if AudioUnitSetParameter(unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0) != noErr {
                    ok = false
                }
            } else {
                ok = false
            }
        }
        set(IsolationProperty.dereverbPreset, kAudioUnitScope_Global, "" as CFString, required: false)

        let started = Date()
        guard ok, AudioUnitInitialize(unit) == noErr else {
            NSLog("[vocal] AUSoundIsolation initialisation failed for %@", model.name)
            AudioComponentInstanceDispose(unit)
            return nil
        }
        var latency: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size)
        latencyFrames = Int((latency * format.sampleRate).rounded())
        NSLog("[vocal] %@ ready in %.0f ms, %d Hz × %d ch, latency %.0f ms", model.name, Date().timeIntervalSince(started) * 1000, Int(format.sampleRate), format.channelCount, latency * 1000)
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }
}

final class InputFeed: @unchecked Sendable {
    let channels: Int
    let maxFrames: Int
    let samples: UnsafeMutablePointer<Float>

    init(channels: Int, maxFrames: Int) {
        self.channels = max(channels, 1)
        self.maxFrames = maxFrames
        samples = .allocate(capacity: self.channels * maxFrames)
        samples.initialize(repeating: 0, count: self.channels * maxFrames)
    }

    deinit { samples.deallocate() }
}

private let feedRenderCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    guard let ioData else { return noErr }
    let feed = Unmanaged<InputFeed>.fromOpaque(refCon).takeUnretainedValue()
    let frames = min(Int(frameCount), feed.maxFrames)
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    for channel in 0..<buffers.count {
        guard let destination = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
        destination.update(from: feed.samples + min(channel, feed.channels - 1) * feed.maxFrames, count: frames)
    }
    return noErr
}

/// Per-sample output gain: linear fades, and a muted stretch (the unit priming) before a fade-in.
struct GainEnvelope {
    private(set) var gain: Float = 1
    private var target: Float = 1
    private var step: Float = 0
    private var mutedFrames = 0

    var isSilent: Bool { gain == 0 && target == 0 && mutedFrames == 0 }
    var isFadingOut: Bool { target == 0 }
    private var isUnity: Bool { gain == 1 && target == 1 && mutedFrames == 0 }

    mutating func fade(to value: Float, over frames: Int) {
        if value > 0 { mutedFrames = 0 }
        target = value
        step = abs(value - gain) / Float(max(frames, 1))
        if step == 0 { gain = value }
    }

    mutating func mute(frames: Int, thenFadeInOver fadeFrames: Int) {
        gain = 0
        mutedFrames = max(frames, 0)
        target = 1
        step = 1 / Float(max(fadeFrames, 1))
    }

    mutating func apply(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard !isUnity else { return }
        for frame in 0..<frameCount {
            let value: Float
            if mutedFrames > 0 {
                mutedFrames -= 1
                value = 0
            } else {
                if gain < target { gain = min(target, gain + step) } else if gain > target { gain = max(target, gain - step) }
                value = gain
            }
            for channel in 0..<buffers.count {
                buffers[channel].mData?.assumingMemoryBound(to: Float.self)[frame] *= value
            }
        }
    }
}
