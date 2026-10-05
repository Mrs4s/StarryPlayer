import AudioProcessing
import AVFoundation
import Foundation
import StarryCore

@MainActor
public final class AVDeckEngine: PlaybackEngine {
    public enum TransitionState: Sendable, Equatable {
        case idle
        case playing
        case armed(next: TrackRef)
        case scheduled(next: TrackRef)
        case overlapping(previous: TrackRef)
    }

    public let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation

    private var decks: [Deck]
    private var activeIndex = 0
    var active: Deck { decks[activeIndex] }
    var idle: Deck { decks[(activeIndex + 1) % decks.count] }

    public private(set) var state: TransitionState = .idle
    public private(set) var currentTrack: TrackRef?
    /// The armed song's download once arming is cancelled (a seek near the end does that): the
    /// song is usually still the next one, so its bytes wait here for its load.
    private var spareDownload: (url: URL, download: ProgressiveDownload)?
    public let processingTap = ProcessingTapHost()

    /// The user's switch. Turning it on builds the separation unit for the playing item and fades
    /// into processed audio; songs loaded later start processed.
    public var vocalAttenuationEnabled = false {
        didSet { if vocalAttenuationEnabled != oldValue { applyVocalControl() } }
    }
    public var vocalLevel: Double = VocalAttenuationCurve.defaultLevel {
        didSet { if vocalLevel != oldValue { applyVocalControl() } }
    }
    /// Network for items loaded from now on (the playing one keeps its unit).
    public var vocalModel: VocalSeparationModel = .systemVoice {
        didSet { if vocalModel != oldValue { applyVocalControl() } }
    }
    public private(set) var vocalStatus = VocalAttenuationStatus()
    private let vocalPolicy = VocalAttenuationPolicy()

    public var equalizer = EqualizerSettings() {
        didSet {
            guard equalizer != oldValue else { return }
            let state = EqualizerControl.state(for: equalizer)
            processingTap.equalizerControl.update { $0 = state }
        }
    }

    /// How songs follow each other unless `arm` says otherwise. Any transition streams remote
    /// files through a download, so their exact end is known (from the next load).
    public var transitionMode: TransitionMode = .none {
        didSet { for deck in decks { deck.downloadsForTransitions = transitionMode != .none } }
    }

    private struct Armed {
        enum Phase: Equatable {
            case waiting
            case prerolling
            case scheduled(CMTime)
            /// Could not be scheduled in time: it starts when the current song ends.
            case atEnd
        }

        var serial: Int
        var track: TrackRef
        var mode: TransitionMode
        var phase = Phase.waiting
        /// The crossfade the fades were set for, in seconds; 0 once the transition is gapless
        /// (a crossfade that does not fit), nil until decided.
        var overlap: Double?
        var shift: Double = 0
    }

    private var armed: Armed?
    private var armSerial = 0
    public var armedTrack: TrackRef? { armed?.track }
    private var outgoing: (deck: Deck, track: TrackRef)?
    private var pivotTask: Task<Void, Never>?
    private var fadeTicker: Task<Void, Never>?
    private var timebaseObservers: [NSObjectProtocol] = []

    /// How long before its start the next song is prerolled and scheduled. A tapped item takes
    /// about 0.5 s from `play()` until it sounds, and a busy main thread can hold the preroll's
    /// answer back; scheduled this far ahead it still starts on time.
    static let scheduleLead: TimeInterval = 3
    /// Less than this before the start, a schedule is not made any more (the next song starts
    /// when the current one ends).
    static let minimumLead: TimeInterval = 0.3
    /// The fades must be in place before the taps reach them: a tap processes about 0.4 s
    /// ahead of what is heard.
    static let fadeLead: TimeInterval = 1
    static let cutFade = PauseFade(steps: 6, duration: 0.15)

    public var pauseFade = PauseFade()
    private var fadeOuts: [(deck: Deck, task: Task<Void, Never>)] = []

    public var volume: Float = 1 {
        didSet { applyVolume() }
    }

    public var loudness = Loudness() {
        didSet {
            guard loudness != oldValue else { return }
            for deck in decks { deck.gain = loudness.factor(for: deck.asset?.gain) }
            applyVolume()
        }
    }

    /// Core Audio UID of the output both decks play through; nil follows the system output.
    /// Takes effect at once, also mid-song.
    public var outputDeviceUID: String? {
        didSet {
            guard outputDeviceUID != oldValue else { return }
            for deck in decks { deck.player.audioOutputDeviceUniqueID = outputDeviceUID }
        }
    }

    /// Streams every remote file (not only FLAC) through one download to disk, and reports each
    /// finished file (`.downloadFinished`), so the song cache can keep what was heard without
    /// downloading it again. Applies from the next load.
    public var keepsDownloads = false {
        didSet { for deck in decks { deck.keepsDownloads = keepsDownloads } }
    }

    public convenience init() {
        self.init(downloadConfiguration: .default)
    }

    init(downloadConfiguration: URLSessionConfiguration) {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self, bufferingPolicy: .bufferingNewest(64))
        decks = [Deck(name: "A", downloadConfiguration: downloadConfiguration), Deck(name: "B", downloadConfiguration: downloadConfiguration)]
        for deck in decks {
            deck.tapHost = processingTap
            deck.onTime = { [weak self, unowned deck] time in
                self?.forward(.time(time), from: deck)
                if self?.active === deck { self?.updateTransition() }
            }
            deck.onDuration = { [weak self, unowned deck] duration in self?.forward(.duration(duration), from: deck) }
            deck.onEnded = { [weak self, unowned deck] in self?.handleEnded(of: deck) }
            deck.onBuffer = { [weak self, unowned deck] state in
                self?.forward(.bufferState(state), from: deck)
                if state == .ready { self?.updateTransition() }
            }
            deck.onFailure = { [weak self, unowned deck] message in self?.forward(.error(.decodeFailed(message)), from: deck) }
            deck.onDownloaded = { [weak self, unowned deck] file in
                guard let self, let track = self.currentTrack else { return }
                self.forward(.downloadFinished(track, file: file), from: deck)
            }
            deck.onProcessingChange = { [weak self] in
                self?.refreshVocalStatus()
                self?.updateTransition()
            }
            deck.onExactEnd = { [weak self] in self?.updateTransition() }
            deck.onItemReplaced = { [weak self, unowned deck] in
                guard let self, deck === self.active || (deck === self.idle && self.armed != nil) else { return }
                self.unschedule()
                self.updateTransition()
            }
        }
        processingTap.onVocalStatusChange = { [weak self] in self?.refreshVocalStatus() }
        vocalPolicy.onChange = { [weak self] in self?.applyVocalControl() }
        applyVocalControl()
    }

    deinit { continuation.finish() }

    public var currentTime: TimeInterval { active.currentTime }
    var rawItemTime: TimeInterval { active.rawTime }
    var activeAttenuatorStatus: SoundIsolationAttenuator.Status? { active.processing?.attenuator.status }
    public var duration: TimeInterval { active.duration }
    public var rate: Float { active.player.rate }

    public func spectrumSnapshot() -> SpectrumAnalyzer.Snapshot { active.processing?.spectrum.snapshot() ?? .silent }

    /// The playing item's audio as decoded: sample rate, channels, the source bit depth of a
    /// lossless file (FLAC / ALAC flags, or PCM bits) and the track's estimated data rate.
    /// Nil before an item has loaded its tracks.
    public func currentFormat() async -> AudioStreamInfo? {
        if let format = active.transcodedFormat { return format }
        guard let asset = active.player.currentItem?.asset,
              let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let (descriptions, dataRate) = try? await track.load(.formatDescriptions, .estimatedDataRate) else { return nil }
        var info = AudioStreamInfo()
        if let description = descriptions.first, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            if basic.mSampleRate > 0 { info.sampleRate = Int(basic.mSampleRate.rounded()) }
            if basic.mChannelsPerFrame > 0 { info.channels = Int(basic.mChannelsPerFrame) }
            info.bitDepth = Self.sourceBitDepth(formatID: basic.mFormatID, flags: basic.mFormatFlags, bitsPerChannel: basic.mBitsPerChannel)
        }
        if dataRate > 0 { info.bitrate = Int(dataRate.rounded()) }
        return info
    }

    /// FLAC/ALAC format flags 1…4 represent source bit depths 16…32.
    nonisolated static func sourceBitDepth(formatID: AudioFormatID, flags: AudioFormatFlags, bitsPerChannel: UInt32) -> Int? {
        switch formatID {
        case kAudioFormatLinearPCM:
            return bitsPerChannel > 0 ? Int(bitsPerChannel) : nil
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            return [1: 16, 2: 20, 3: 24, 4: 32][flags]
        default:
            return nil
        }
    }

    public func load(_ asset: PlayableAsset, track: TrackRef, autoplay: Bool, startAt: TimeInterval?) async throws {
        continuation.yield(.itemWillChange(to: track))
        cancelArmed()
        retireOutgoing(fading: true)
        endFadeOuts(pausing: true)
        active.load(asset, volume: volume, gain: loudness.factor(for: asset.gain), download: takeSpareDownload(for: asset))
        currentTrack = track
        refreshVocalStatus()
        state = .playing
        continuation.yield(.itemDidChange(track))
        if let startAt { await active.seek(to: startAt) }
        if autoplay { play() }
    }

    /// Loads `asset` on the idle deck to follow the current song, with `mode` (the engine's
    /// `transitionMode` when nil). Refused (false) while something is armed already or the
    /// previous song still fades out.
    @discardableResult
    public func arm(next asset: PlayableAsset, track: TrackRef, mode: TransitionMode? = nil) async -> Bool {
        guard state == .playing, currentTrack != nil, outgoing == nil else { return false }
        let mode = asset.supportsOverlap && active.asset?.supportsOverlap == true ? mode ?? transitionMode : .none
        idle.load(asset, volume: mode == .none ? 0 : volume, gain: loudness.factor(for: asset.gain), download: takeSpareDownload(for: asset))
        idle.player.pause()
        armSerial += 1
        armed = Armed(serial: armSerial, track: track, mode: mode)
        state = .armed(next: track)
        let end = active.exactEnd?.seconds ?? duration
        continuation.yield(.transitionArmed(mode: mode, overlapStart: max(0, end - (mode.crossfadeSeconds ?? 0))))
        updateTransition()
        return true
    }

    public func cancelArmed() {
        guard armed != nil else { return }
        unschedule()
        active.fades = TransitionFades()
        active.fadeGain = 1
        armed = nil
        setSpareDownload(idle.takeDownload())
        idle.unload()
        stopFadeTickerIfIdle()
        state = .playing
        applyVolume()
        continuation.yield(.transitionCancelled(.skip))
    }

    public func play() {
        endFadeOuts(pausing: false)
        for deck in playingDecks {
            deck.player.volume = outputVolume(of: deck)
            deck.wantsPlayback = true
            deck.player.play()
        }
        continuation.yield(.rate(1))
    }

    public func pause(fade: Bool) {
        endFadeOuts(pausing: false)
        unschedule()
        for deck in playingDecks {
            deck.wantsPlayback = false
            if fade {
                let task = Task { @MainActor [weak self, pauseFade] in
                    guard await pauseFade.run(on: deck.player, from: deck.player.volume) else { return }
                    deck.player.pause()
                    self?.fadeOuts.removeAll { $0.deck === deck }
                }
                fadeOuts.append((deck, task))
            } else {
                deck.player.pause()
            }
        }
        continuation.yield(.rate(0))
    }

    public func stop() {
        cancelArmed()
        retireOutgoing(fading: false)
        setSpareDownload(nil)
        endFadeOuts(pausing: true)
        active.unload()
        currentTrack = nil
        state = .idle
        refreshVocalStatus()
        continuation.yield(.itemDidChange(nil))
        continuation.yield(.rate(0))
    }

    public func seek(to time: TimeInterval) async {
        if let armed, armed.mode != .none {
            // The next song does not depend on where this one is: only its start moves.
            unschedule()
        } else {
            cancelArmed()
        }
        if outgoing != nil {
            retireOutgoing(fading: true)
            active.fades = TransitionFades()
            active.fadeGain = 1
            applyVolume()
        }
        let deck = active
        // A seek overtaken by another seek or a new item reports nothing: its target is not
        // the position of what plays now.
        guard await deck.seek(to: time), deck === active else { return }
        continuation.yield(.time(time))
        updateTransition()
    }

    private func updateTransition() {
        guard var next = armed, next.mode != .none, outgoing == nil, next.phase == .waiting else { return }
        let current = active, incoming = idle
        // `play()` precedes audible playback; the timebase cannot provide host timing until audio
        // starts.
        guard current.wantsPlayback, current.player.rate > 0, current.isClockRunning, let end = current.exactEnd?.seconds else { return }
        let now = current.rawTime
        if next.overlap == nil {
            guard let overlap = next.mode.crossfadeSeconds, overlap > 0 else {
                next.overlap = 0
                armed = next
                return updateTransition()
            }
            guard incoming.isReady, !incoming.isAttachingTap else { return }
            let incomingLength = incoming.asset?.range.map { $0.upperBound - $0.lowerBound } ?? incoming.duration
            let fits = end - current.startTime >= 2 * overlap && incomingLength >= 2 * overlap
            if fits, now + Self.fadeLead < end - overlap {
                current.fades = TransitionFades(fadeOut: (end - overlap)...end)
                incoming.fades = TransitionFades(fadeIn: incoming.startTime...(incoming.startTime + overlap))
                if !incoming.fadesInTap {
                    incoming.fadeGain = 0
                    applyVolume()
                }
                next.overlap = overlap
            } else {
                next.overlap = 0
            }
        }
        let start = end - (next.overlap ?? 0)
        guard now >= start - Self.scheduleLead else {
            armed = next
            return
        }
        guard now < start - Self.minimumLead else {
            next.phase = .atEnd
            armed = next
            return
        }
        guard incoming.isReady, !incoming.isAttachingTap else {
            armed = next
            return
        }
        next.phase = .prerolling
        armed = next
        schedule(serial: next.serial, start: start)
    }

    private func schedule(serial: Int, start: TimeInterval) {
        let current = active, incoming = idle
        Task { @MainActor [weak self] in
            let prerolled = await incoming.player.preroll(atRate: 1)
            guard let self, var next = self.armed, next.serial == serial, next.phase == .prerolling, self.active === current else { return }
            guard prerolled, current.player.rate > 0, current.isClockRunning, let timebase = current.itemTimebase else {
                next.phase = .waiting
                self.armed = next
                return
            }
            // Vocal attenuation holds what is heard back by its latency, and a song it processes starts with
            // that much silence while the unit primes: the next one starts that much earlier.
            if let processing = current.processing, processing.attenuator.status.isProcessing, incoming.fadesInTap {
                next.shift = processing.attenuator.latency
            }
            let at = CMSyncConvertTime(CMTime(seconds: start, preferredTimescale: 1_000_000_000), from: timebase, to: CMClockGetHostTimeClock())
                - CMTime(seconds: next.shift, preferredTimescale: 1_000_000_000)
            let lead = (at - CMClockGetTime(CMClockGetHostTimeClock())).seconds
            guard lead.isFinite, lead > Self.minimumLead else {
                next.phase = .atEnd
                self.armed = next
                return
            }
            incoming.player.setRate(1, time: CMTime(seconds: incoming.startTime, preferredTimescale: 1_000_000_000), atHostTime: at)
            NSLog("[engine] %@ scheduled %@ in %.2f s (at %.3f of %.3f s)", (next.overlap ?? 0) > 0 ? "crossfade \(next.overlap ?? 0) s" : "gapless", next.track.id, lead, start, current.exactEnd?.seconds ?? 0)
            next.phase = .scheduled(at)
            self.armed = next
            self.state = .scheduled(next: next.track)
            self.watchTimebase(of: current)
            self.startFadeTicker()
            self.pivotTask?.cancel()
            self.pivotTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(lead))
                guard !Task.isCancelled else { return }
                self?.pivot(serial: serial)
            }
        }
    }

    private func unschedule() {
        guard var next = armed, next.phase != .waiting else { return }
        let wasStarted = next.phase != .atEnd
        next.phase = .waiting
        armed = next
        pivotTask?.cancel()
        pivotTask = nil
        stopWatchingTimebase()
        fadeTicker?.cancel()
        fadeTicker = nil
        if wasStarted {
            let incoming = idle
            incoming.player.cancelPendingPrerolls()
            incoming.player.pause()
            // Only if it had begun already: a seek would cancel the next preroll.
            if abs(incoming.rawTime - incoming.startTime) > 0.001 {
                incoming.player.seek(to: CMTime(seconds: incoming.startTime, preferredTimescale: 1_000_000_000), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        state = .armed(next: next.track)
    }

    /// The next song is playing (or about to, within milliseconds): it becomes the current one.
    /// The previous song plays on (fading) on the idle deck until it ends.
    private func pivot(serial: Int) {
        guard let next = armed, next.serial == serial, case .scheduled(let at) = next.phase, let previous = currentTrack else { return }
        pivotTask = nil
        stopWatchingTimebase()
        let previousDeck = active
        let incoming = idle
        // The previous song ended before the start (its audio is shorter than its header said),
        // or the start was lost (the item was replaced): the next song starts now, not later.
        if incoming.player.rate == 0 || (at - CMClockGetTime(CMClockGetHostTimeClock())).seconds > 0.05 {
            NSLog("[engine] %@ starts now instead of as scheduled", next.track.id)
            // A start still pending holds the rate at 1: `play()` alone would leave it pending.
            incoming.player.pause()
            incoming.player.play()
        }
        activeIndex = (activeIndex + 1) % decks.count
        armed = nil
        active.wantsPlayback = true
        currentTrack = next.track
        outgoing = (previousDeck, previous)
        let crossfading = (next.overlap ?? 0) > 0
        state = crossfading ? .overlapping(previous: previous) : .playing
        announcePivot(crossfading: crossfading)
    }

    /// The current song ended with the next one armed but not scheduled (no exact end, not
    /// ready in time): it starts now, without fades.
    private func startArmedNow() -> Bool {
        guard let next = armed, next.mode != .none, idle.isReady else { return false }
        NSLog("[engine] %@ starts at the end (%@)", next.track.id, active.exactEnd == nil ? "end not known exactly" : "not scheduled in time")
        let previousDeck = active
        let incoming = idle
        incoming.fades = TransitionFades()
        incoming.fadeGain = 1
        incoming.player.volume = outputVolume(of: incoming)
        incoming.wantsPlayback = true
        incoming.player.play()
        activeIndex = (activeIndex + 1) % decks.count
        armed = nil
        currentTrack = next.track
        previousDeck.unload()
        stopFadeTickerIfIdle()
        state = .playing
        announcePivot(crossfading: false)
        return true
    }

    /// What `load` would have reported for the new song, which the idle deck could not say.
    private func announcePivot(crossfading: Bool) {
        guard let track = currentTrack else { return }
        if crossfading { continuation.yield(.transitionBegan) }
        continuation.yield(.transitionPivoted(track))
        refreshVocalStatus()
        if active.duration > 0 { continuation.yield(.duration(active.duration)) }
        continuation.yield(.bufferState(.ready))
        continuation.yield(.rate(1))
        if let file = active.downloadedFile { continuation.yield(.downloadFinished(track, file: file)) }
    }

    private func retireOutgoing(fading: Bool) {
        guard let (deck, _) = outgoing else { return }
        outgoing = nil
        if fading, deck.player.rate > 0 {
            let token = deck.loadToken
            deck.wantsPlayback = false
            Task { @MainActor in
                let fade = Self.cutFade
                let start = deck.player.volume
                for step in 1...fade.steps {
                    try? await Task.sleep(for: .seconds(fade.duration / Double(fade.steps)))
                    guard deck.loadToken == token else { return }
                    deck.player.volume = start * Float(fade.steps - step) / Float(fade.steps)
                }
                deck.unload()
            }
        } else {
            deck.unload()
        }
        if case .overlapping = state { state = .playing }
        active.fades = TransitionFades()
        active.fadeGain = 1
        stopFadeTickerIfIdle()
        applyVolume()
        continuation.yield(.transitionEnded)
    }

    private func watchTimebase(of deck: Deck) {
        stopWatchingTimebase()
        guard let timebase = deck.itemTimebase else { return }
        for name in [CMTimebase.effectiveRateChanged, CMTimebase.timeJumped] {
            timebaseObservers.append(NotificationCenter.default.addObserver(forName: name, object: timebase, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.timebaseChanged() }
            })
        }
    }

    private func stopWatchingTimebase() {
        for observer in timebaseObservers { NotificationCenter.default.removeObserver(observer) }
        timebaseObservers.removeAll()
    }

    private func timebaseChanged() {
        guard let next = armed, case .scheduled(let at) = next.phase else { return }
        // A gapless song stops at its end the moment the next one starts; a busy main thread
        // may hear of that before the pivot's timer fires. That is the pivot, not a change.
        if (CMClockGetTime(CMClockGetHostTimeClock()) - at).seconds > -0.05 {
            pivot(serial: next.serial)
            return
        }
        let current = active
        if current.player.rate > 0, let timebase = current.itemTimebase, let end = current.exactEnd?.seconds {
            let start = end - (next.overlap ?? 0)
            let expected = CMSyncConvertTime(CMTime(seconds: start, preferredTimescale: 1_000_000_000), from: timebase, to: CMClockGetHostTimeClock())
            if abs((expected - at).seconds - next.shift) < 0.002 { return }
        }
        unschedule()
        updateTransition()
    }

    private func startFadeTicker() {
        guard fadeTicker == nil, decks.contains(where: { !$0.fades.isEmpty && !$0.fadesInTap }) else { return }
        fadeTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for deck in self.decks where !deck.fades.isEmpty && !deck.fadesInTap {
                    deck.fadeGain = deck.fades.gain(at: deck.rawTime)
                }
                self.applyVolume()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopFadeTickerIfIdle() {
        guard decks.allSatisfy({ $0.fades.isEmpty || $0.fadesInTap }) else { return }
        fadeTicker?.cancel()
        fadeTicker = nil
    }

    private var playingDecks: [Deck] {
        [active] + (outgoing.map { [$0.deck] } ?? [])
    }

    private func outputVolume(of deck: Deck) -> Float {
        volume * deck.gain * deck.fadeGain
    }

    private func applyVolume() {
        guard fadeOuts.isEmpty else { return }
        for deck in playingDecks { deck.player.volume = outputVolume(of: deck) }
        if let armed { idle.player.volume = armed.mode == .none ? 0 : outputVolume(of: idle) }
    }

    private func setSpareDownload(_ spare: (url: URL, download: ProgressiveDownload)?) {
        spareDownload?.download.cancel()
        spareDownload = spare
    }

    private func takeSpareDownload(for asset: PlayableAsset) -> ProgressiveDownload? {
        guard let spare = spareDownload else { return nil }
        spareDownload = nil
        guard spare.url == asset.url else {
            spare.download.cancel()
            return nil
        }
        return spare.download
    }

    private func applyVocalControl() {
        let enabled = vocalAttenuationEnabled
        let level = vocalLevel
        let model = vocalModel
        let suspended = vocalPolicy.blockingReason != nil
        processingTap.vocalControl.update {
            $0.enabled = enabled
            $0.vocalLevel = level
            $0.model = model
            $0.suspended = suspended
        }
        if enabled, !suspended {
            for deck in decks { deck.processing?.attenuator.prepareUnitIfNeeded() }
        }
        refreshVocalStatus()
    }

    private func refreshVocalStatus() {
        var status = VocalAttenuationStatus()
        status.enabled = vocalAttenuationEnabled
        switch active.tapState {
        case .none:
            break
        case .attaching:
            status.isPreparing = vocalAttenuationEnabled
        case .unavailable:
            status.unavailable = active.playsSpatialMix ? .spatialMix : .unsupportedSource
        case .attached(let processing):
            let item = processing.attenuator.status
            status.isActive = item.isProcessing
            status.isPreparing = item.isPreparing || (vocalAttenuationEnabled && item.model == nil && !item.unsupportedFormat && item.sampleRate == 0)
            status.modelName = item.model?.name
            status.usesMusicModel = item.model?.output == .accompaniment
            status.latency = item.latency
            if item.unsupportedFormat { status.unavailable = .unsupportedSource }
            if item.failedPerformance { status.unavailable = .performance }
        }
        if let reason = vocalPolicy.blockingReason { status.unavailable = reason }
        if status.unavailable != nil { status.isPreparing = false }
        guard status != vocalStatus else { return }
        vocalStatus = status
        continuation.yield(.vocalAttenuation(status))
    }

    private func endFadeOuts(pausing: Bool) {
        for fadeOut in fadeOuts {
            fadeOut.task.cancel()
            if pausing { fadeOut.deck.player.pause() }
        }
        fadeOuts.removeAll()
    }

    /// Only the active deck speaks for the current track. The idle deck holding the armed next
    /// item becomes ready ~30 s before the end, and the previous song plays on there after a
    /// pivot; their duration / time / buffer state must not replace the current track's.
    private func forward(_ event: PlaybackEvent, from deck: Deck) {
        guard deck === active else { return }
        continuation.yield(event)
    }

    private func handleEnded(of deck: Deck) {
        if let outgoing, deck === outgoing.deck {
            retireOutgoing(fading: false)
            return
        }
        guard deck === active, let track = currentTrack else { return }
        // The scheduled next song has started (or does so within milliseconds) and the main
        // thread only now got round to it.
        if let armed, case .scheduled = armed.phase {
            pivot(serial: armed.serial)
            retireOutgoing(fading: false)
            return
        }
        if startArmedNow() { return }
        continuation.yield(.playbackEnded(track))
    }
}

public struct PauseFade: Sendable {
    public var steps = 10
    public var duration: TimeInterval = 0.3

    public init() {}

    public init(steps: Int, duration: TimeInterval) {
        self.steps = steps
        self.duration = duration
    }

    /// Ramps `player.volume` from `start` to 0. Returns false when cancelled part-way; the caller
    /// must then leave the player alone (a resume has already restored its volume).
    @MainActor
    func run(on player: AVPlayer, from start: Float) async -> Bool {
        guard steps > 0 else { return !Task.isCancelled }
        let stepTime = UInt64(duration / Double(steps) * 1_000_000_000)
        for i in 1...steps {
            guard !Task.isCancelled else { return false }
            player.volume = start * Float(steps - i) / Float(steps)
            try? await Task.sleep(nanoseconds: stepTime)
        }
        return !Task.isCancelled
    }
}

extension TransitionMode {
    var crossfadeSeconds: Double? {
        if case .crossfade(let seconds) = self { return seconds }
        return nil
    }
}

@MainActor
final class Deck {
    let name: String
    let player = AVPlayer()
    private var item: AVPlayerItem? {
        didSet { timebase = item?.timebase }
    }
    /// Read the stable timebase directly: `currentTime()` synchronizes with the item's queue.
    private var timebase: CMTimebase?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?

    var onTime: ((TimeInterval) -> Void)?
    var onDuration: ((TimeInterval) -> Void)?
    var onEnded: (() -> Void)?
    var onBuffer: ((BufferState) -> Void)?
    var onFailure: ((String) -> Void)?
    var onDownloaded: ((URL) -> Void)?
    /// The tap state changed (attached or not).
    var onProcessingChange: (() -> Void)?
    var onItemReplaced: (() -> Void)?
    var onExactEnd: (() -> Void)?
    var tapHost: ProcessingTapHost?

    /// The song's crossfade fades (`TransitionFades`), one control per load so a song's fades
    /// never reach the next one. A tapped item applies them in its tap; an untapped one (HLS, a
    /// spatial mix) through `fadeGain`, which the engine steps from the item's clock.
    private var fadeControl = TransitionEnvelopeControl()
    var fades: TransitionFades {
        get { fadeControl.fades }
        set { fadeControl.fades = newValue }
    }
    /// Gain of the fades on an untapped item, part of the player's volume (1 otherwise).
    var fadeGain: Float = 1
    var fadesInTap: Bool { processing != nil }

    enum TapState {
        case none
        case attaching
        /// The source cannot take a tap (HLS) or attaching failed.
        case unavailable
        case attached(ItemProcessing)
    }

    private(set) var tapState: TapState = .none {
        didSet { onProcessingChange?() }
    }

    var processing: ItemProcessing? {
        if case .attached(let processing) = tapState { return processing }
        return nil
    }

    /// Item time minus the tap's latency, held instead of running backwards.
    private var clock = HeardClock()

    var wantsPlayback = false
    private var stalled = false

    // MARK: FLAC / Ogg timing
    //
    // AVFoundation estimates FLAC/Ogg seeks inaccurately without reading the whole file.
    // Start streaming, then use a precise local copy for seeks once downloaded.
    // Vorbis instead uses granule-timed PCM transcoding.

    private let downloadConfiguration: URLSessionConfiguration
    /// Every remote file streams through a `ProgressiveDownload`, not only FLAC.
    var keepsDownloads = false
    private var playable: PlayableAsset?
    private var loadID = 0
    private var download: ProgressiveDownload?
    private var preciseCopy: AVURLAsset?
    private var playsPreciseCopy = false
    /// The item's time comes from a seek by estimate: what is heard may be seconds away from it.
    private var positionUncertain = false
    /// Ogg Vorbis decoded by us into the PCM the item plays; nil when AVFoundation decodes.
    private var transcode: VorbisTranscode?
    private var reportedDownload = false
    private(set) var downloadedFile: URL?
    /// The song's duration read with precise timing from its finished download (for a file
    /// AVFoundation times by estimate otherwise, MP3 among them).
    private var exactDuration: CMTime?
    /// Stream remote files through a download so their exact end is known (gapless / crossfade).
    var downloadsForTransitions = false

    var gain: Float = 1
    var asset: PlayableAsset? { playable }

    /// Seeks in the current item land where AVFoundation estimates.
    private var seeksByEstimate: Bool { (playable.map(Self.estimatesTiming) ?? false) && !playsPreciseCopy && transcode == nil }
    var hasPreciseCopy: Bool { preciseCopy != nil }
    var playsSpatialMix: Bool { playable?.tier.isSpatial == true }
    var isPlayingPreciseCopy: Bool { playsPreciseCopy }
    var isTranscoding: Bool { transcode != nil }
    var transcoder: VorbisTranscode? { transcode }
    var transcodedFormat: AudioStreamInfo? { transcode?.sourceFormat }

    init(name: String, downloadConfiguration: URLSessionConfiguration = .default) {
        self.name = name
        self.downloadConfiguration = downloadConfiguration
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        // 4 Hz is plenty for time labels and progress bars (the lyrics read the item clock
        // themselves every frame); every event re-evaluates the SwiftUI pages showing the time.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.item != nil else { return }
                self.transcode?.update(playhead: self.rawTime)
                self.onTime?(self.currentTime)
            }
        }
    }

    var rawTime: TimeInterval {
        guard let item else { return 0 }
        let t = (timebase.map { CMTimebaseGetTime($0) } ?? item.currentTime()).seconds
        return t.isFinite ? t : 0
    }

    var currentTime: TimeInterval {
        guard item != nil else { return 0 }
        return clock.time(raw: rawTime, latency: processing?.attenuator.latency ?? 0)
    }

    var duration: TimeInterval {
        guard let item else { return 0 }
        let d = item.duration.seconds
        return d.isFinite ? d : 0
    }

    var isReady: Bool { item?.status == .readyToPlay }
    var isClockRunning: Bool { timebase.map { CMTimebaseGetRate($0) > 0 } ?? false }
    var isAttachingTap: Bool {
        if case .attaching = tapState { return true }
        return false
    }
    var loadToken: Int { loadID }
    var itemTimebase: CMTimebase? { timebase }
    var startTime: TimeInterval { playable?.range?.lowerBound ?? 0 }

    /// Where the song's audio really ends, in item time, when that is known to the sample; nil
    /// while only AVFoundation's estimate is (an MP3 stream reads tens of milliseconds long, a FLAC
    /// stream seconds off), and for HLS. Gapless and crossfade are scheduled from it.
    var exactEnd: CMTime? {
        guard let item, item.status == .readyToPlay, let playable else { return nil }
        let itemDuration = item.duration.isNumeric ? item.duration : nil
        if let range = playable.range {
            let end = CMTime(seconds: range.upperBound, preferredTimescale: 1_000_000_000)
            guard let known = exactDuration ?? (playsPreciseCopy ? itemDuration : nil) else { return end }
            return CMTimeMinimum(end, known)
        }
        if playsPreciseCopy || transcode != nil { return itemDuration }
        if let exactDuration { return exactDuration }
        if ["m4a", "mp4", "m4b"].contains(playable.url.pathExtension.lowercased()) || playable.container == .alac || playable.container == .mp4 { return itemDuration }
        return nil
    }

    /// Plays `asset` from its start. `download` is an earlier download of the same file (the
    /// armed next song's), handed over so its bytes are not fetched again.
    func load(_ asset: PlayableAsset, volume: Float, gain: Float = 1, download handedOver: ProgressiveDownload? = nil) {
        unload()
        playable = asset
        self.gain = gain
        player.volume = volume * gain
        if downloads(asset) {
            // A scrambled file is stored unscrambled, so it is named for what it holds.
            let pathExtension = asset.url.pathExtension.isEmpty || asset.decryption != nil ? asset.container.rawValue : asset.url.pathExtension.lowercased()
            let download = handedOver ?? ProgressiveDownload(url: asset.url, headers: asset.headers, fileExtension: pathExtension, decryptor: asset.decryption?.decryptor, configuration: downloadConfiguration)
            self.download = download
            watch(download, asset: asset)
            download.start()
        } else {
            handedOver?.cancel()
        }
        if asset.container == .ogg, VorbisDecoder.isAvailable, let source: ByteSource = download ?? (asset.url.isFileURL ? LocalFileSource(url: asset.url) : nil) {
            let transcode = VorbisTranscode(source: source, directory: ProgressiveDownload.directory)
            let id = loadID
            transcode.onUnsupported = { [weak self, weak transcode] in
                guard let self, self.loadID == id, let transcode, self.transcode === transcode else { return }
                self.decodeNatively(asset)
            }
            self.transcode = transcode
            transcode.start()
            install(transcode.makeAsset())
        } else {
            install(nativeAsset(for: asset))
            preparePreciseTiming(of: asset)
        }
        clock.reset(to: asset.range?.lowerBound ?? 0)
        startAtRange(of: asset)
    }

    /// The asset AVFoundation decodes itself: the download's, or the address. A file on this Mac's
    /// own disks is opened with precise timing at once: that reads little more than its headers,
    /// and without it a VBR MP3 lacking a frame count plays only as long as its first frames
    /// suggest.
    private func nativeAsset(for asset: PlayableAsset) -> AVURLAsset {
        if let download { return download.makeAsset() }
        var options: [String: Any] = [:]
        if !asset.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = asset.headers }
        if Self.isOnLocalDisk(asset.url) {
            options[AVURLAssetPreferPreciseDurationAndTimingKey] = true
            playsPreciseCopy = true
        }
        return AVURLAsset(url: asset.url, options: options)
    }

    /// Use estimated timing on network volumes so playback does not wait for a full remote scan.
    private func preparePreciseTiming(of asset: PlayableAsset) {
        guard asset.url.isFileURL, !playsPreciseCopy, Self.estimatesTiming(asset) || asset.container == .mp3 else { return }
        preparePreciseCopy(of: asset.url)
    }

    static func isOnLocalDisk(_ url: URL) -> Bool {
        url.isFileURL && ((try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true)
    }

    private func startAtRange(of asset: PlayableAsset) {
        guard let range = asset.range else { return }
        player.seek(to: CMTime(seconds: range.lowerBound, preferredTimescale: 600))
        positionUncertain = seeksByEstimate && range.lowerBound > 0
    }

    /// Reports the finished file once per load, and for a file AVFoundation times by estimate
    /// opens the precise copy. Called again when a transcode falls back (it runs at once when
    /// the file is already in).
    private func watch(_ download: ProgressiveDownload, asset: PlayableAsset) {
        let id = loadID
        download.whenComplete { [weak self] file in
            guard let self, self.loadID == id else { return }
            self.downloadedFile = file
            if Self.estimatesTiming(asset), self.transcode == nil, self.preciseCopy == nil {
                self.preparePreciseCopy(of: file)
            } else if self.transcode == nil, self.exactDuration == nil {
                self.readExactDuration(of: file)
            }
            if !self.reportedDownload {
                self.reportedDownload = true
                self.onDownloaded?(file)
            }
        }
    }

    /// The Ogg file is not one the transcode plays (Opus, more than two channels…): AVFoundation
    /// decodes it after all. Nothing had been served, so the item had not started.
    private func decodeNatively(_ asset: PlayableAsset) {
        detachItem()
        player.replaceCurrentItem(with: nil)
        transcode?.cancel()
        transcode = nil
        install(nativeAsset(for: asset))
        if wantsPlayback { player.play() }
        if let download {
            watch(download, asset: asset)
        } else {
            preparePreciseTiming(of: asset)
        }
        startAtRange(of: asset)
    }

    /// Remote FLAC and Ogg always stream through a download (precise seeks need the whole file),
    /// and so do a scrambled file (the download unscrambles it) and a transcode (it has no
    /// length and no ranges: the item waits for all of it); other remote files do with
    /// `keepsDownloads`, except HLS, trial excerpts and windows of a file.
    private func downloads(_ asset: PlayableAsset) -> Bool {
        guard !asset.url.isFileURL else { return false }
        if Self.estimatesTiming(asset) || asset.decryption != nil { return true }
        return (keepsDownloads || downloadsForTransitions) && asset.container != .hls && !asset.isTrial && asset.range == nil
    }

    func takeDownload() -> (url: URL, download: ProgressiveDownload)? {
        guard let download, let url = playable?.url else { return nil }
        self.download = nil
        return (url, download)
    }

    private func install(_ urlAsset: AVURLAsset) {
        let replacing = item != nil
        detachItem()
        let item = AVPlayerItem(asset: urlAsset)
        item.audioTimePitchAlgorithm = .spectral
        item.preferredForwardBufferDuration = 15
        if let range = playable?.range {
            item.forwardPlaybackEndTime = CMTime(seconds: range.upperBound, preferredTimescale: 600)
        }
        let spatial = playable?.tier.isSpatial == true
        if spatial { item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel }
        self.item = item
        player.replaceCurrentItem(with: item)
        if playable?.supportsTap == true, !spatial, let tapHost {
            tapState = .attaching
            let fades = fadeControl
            Task { [weak self] in
                let processing = await tapHost.attach(to: item, asset: urlAsset, fades: fades)
                guard let self, self.item === item else { return }
                self.tapState = processing.map { .attached($0) } ?? .unavailable
            }
        } else {
            tapState = .unavailable
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.onBuffer?(.ready)
                    self.onDuration?(self.duration)
                case .failed:
                    self.onFailure?(item.error?.localizedDescription ?? "unknown")
                default:
                    self.onBuffer?(.buffering)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }
        stallObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, item === self.item else { return }
                self.stalled = true
                self.onBuffer?(.stalled)
                self.resumeAfterStall()
            }
        }
        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item === self.item else { return }
                self.resumeAfterStall()
            }
        }
        if replacing { onItemReplaced?() }
    }

    private func resumeAfterStall() {
        guard stalled, let item, item.isPlaybackLikelyToKeepUp else { return }
        stalled = false
        guard wantsPlayback, player.rate == 0 else { return }
        player.play()
        onBuffer?(.ready)
    }

    private func detachItem() {
        statusObservation = nil
        keepUpObservation = nil
        stalled = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        endObserver = nil
        stallObserver = nil
        item = nil
    }

    func unload() {
        detachItem()
        loadID += 1
        wantsPlayback = false
        tapState = .none
        clock.reset(to: 0)
        player.replaceCurrentItem(with: nil)
        transcode?.cancel()
        transcode = nil
        reportedDownload = false
        downloadedFile = nil
        exactDuration = nil
        fadeControl = TransitionEnvelopeControl()
        fadeGain = 1
        download?.cancel()
        download = nil
        playable = nil
        preciseCopy = nil
        playsPreciseCopy = false
        positionUncertain = false
    }

    /// Containers AVFoundation times by estimate unless the whole file is read first.
    static func estimatesTiming(_ container: AudioContainer) -> Bool {
        container == .flac || container == .ogg
    }

    static func estimatesTiming(_ asset: PlayableAsset) -> Bool {
        estimatesTiming(asset.container) || asset.isTranscode
    }

    /// Opens `file` with precise timing and loads what the item needs from it off the main
    /// thread (reading the whole file); synchronous reads of an asset that has not would block
    /// until then.
    private func preparePreciseCopy(of file: URL) {
        let id = loadID
        let copy = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        Task { [weak self] in
            guard let (duration, _) = try? await copy.load(.duration, .tracks) else { return }
            guard let self, self.loadID == id else { return }
            self.preciseCopy = copy
            self.setExactDuration(duration)
            if self.positionUncertain || self.playable?.isTranscode == true { await self.switchToPreciseCopy(at: self.rawTime) }
        }
    }

    /// Reads the finished file's duration with precise timing, off the main thread: for an MP3
    /// that is the trimmed length its LAME header gives (or a scan of its frames).
    private func readExactDuration(of file: URL) {
        let id = loadID
        let copy = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        Task { [weak self] in
            guard let duration = try? await copy.load(.duration) else { return }
            guard let self, self.loadID == id else { return }
            self.setExactDuration(duration)
        }
    }

    private func setExactDuration(_ duration: CMTime) {
        guard duration.isNumeric, duration > .zero else { return }
        exactDuration = duration
        onExactEnd?()
    }

    @discardableResult
    private func switchToPreciseCopy(at time: TimeInterval) async -> Bool {
        guard let preciseCopy, !playsPreciseCopy else { return false }
        playsPreciseCopy = true
        positionUncertain = false
        install(preciseCopy)
        // A stall in the stream (a seek into bytes not there yet) had paused the player.
        if wantsPlayback, player.rate == 0 { player.play() }
        guard let item else { return false }
        let finished = await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        guard finished, self.item === item else { return false }
        clock.reset(to: time)
        return true
    }

    /// Returns false when the seek did not land on the item it was made for: another seek
    /// overtook it, or another item was loaded while it waited for data (a slow network, an
    /// expired address). The clock then stays as it is; resetting it would make the old target
    /// the new item's floor and hold its time there.
    @discardableResult
    func seek(to time: TimeInterval) async -> Bool {
        if preciseCopy != nil, !playsPreciseCopy { return await switchToPreciseCopy(at: time) }
        guard let item else { return false }
        transcode?.update(playhead: time)
        let byEstimate = seeksByEstimate
        let finished = await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        guard finished, self.item === item else { return false }
        // The start of the file is the one place the estimate cannot miss.
        if byEstimate { positionUncertain = time > 0 }
        clock.reset(to: time)
        return true
    }
}
