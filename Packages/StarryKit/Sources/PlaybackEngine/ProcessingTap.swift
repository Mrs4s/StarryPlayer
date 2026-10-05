import AudioProcessing
import AVFoundation
import Foundation
import MediaToolbox

/// Each item needs its own stateful filters because decks overlap during crossfades.
final class ItemProcessing: @unchecked Sendable {
    let chain = AudioProcessorChain()
    let attenuator: SoundIsolationAttenuator
    let equalizer: EqualizerProcessor
    let envelope: TransitionEnvelope
    let spectrum = SpectrumAnalyzer()
    var isFloat = true
    var sampleRate: Double = 0

    init(control: VocalAttenuationControl, equalizer equalizerControl: EqualizerControl, fades: TransitionEnvelopeControl, onStatusChange: @escaping @Sendable () -> Void) {
        attenuator = SoundIsolationAttenuator(control: control, onStatusChange: onStatusChange)
        equalizer = EqualizerProcessor(control: equalizerControl)
        envelope = TransitionEnvelope(control: fades)
        chain.append(attenuator)
        chain.append(equalizer)
        chain.append(envelope)
        chain.append(spectrum)
    }
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<ItemProcessing>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, format in
    let context = Unmanaged<ItemProcessing>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let flags = format.pointee.mFormatFlags
    context.isFloat = (flags & kAudioFormatFlagIsFloat) != 0 && (flags & kAudioFormatFlagIsNonInterleaved) != 0
    context.sampleRate = format.pointee.mSampleRate
    let processingFormat = ProcessingFormat(sampleRate: format.pointee.mSampleRate, channelCount: Int(format.pointee.mChannelsPerFrame), maxFrames: Int(maxFrames))
    if context.isFloat {
        context.chain.prepare(format: processingFormat)
    } else {
        context.attenuator.markUnsupported(sampleRate: processingFormat.sampleRate)
    }
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    var range = CMTimeRange()
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &range, numberFramesOut)
    guard status == noErr else { return }
    let context = Unmanaged<ItemProcessing>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    guard context.isFloat else { return }
    let start = range.start
    let index: Int64? = start.isValid && start.isNumeric && context.sampleRate > 0 ? Int64((start.seconds * context.sampleRate).rounded()) : nil
    context.chain.process(UnsafeMutableAudioBufferListPointer(bufferListInOut), frameCount: Int(numberFramesOut.pointee), sampleIndex: index)
}

@MainActor
public final class ProcessingTapHost {
    public let vocalControl = VocalAttenuationControl()
    public let equalizerControl = EqualizerControl()
    /// Runs on the main actor when an item's attenuator status changes.
    var onVocalStatusChange: (() -> Void)?

    public init() {}

    /// Creates a fresh tap (one per item) and installs it as the item's audio mix once the
    /// asset's audio track is known. `fades` are the song's crossfade fades (the deck keeps
    /// them for the song, across items). Nil when the tap cannot be attached.
    func attach(to item: AVPlayerItem, asset: AVURLAsset, fades: TransitionEnvelopeControl = TransitionEnvelopeControl()) async -> ItemProcessing? {
        let context = ItemProcessing(control: vocalControl, equalizer: equalizerControl, fades: fades) { [weak self] in
            MainActor.assumeIsolated { self?.onVocalStatusChange?() }
        }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<ItemProcessing>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { return nil }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
            return context
        } catch {
            NSLog("[tap] audio track load failed: %@", String(describing: error))
            return nil
        }
    }
}
