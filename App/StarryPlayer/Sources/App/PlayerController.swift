import AppKit
import AudioProcessing
import Backdrop
import Library
import LyricsCore
import LyricsProviders
import LyricsSync
import Observation
import PlaybackEngine
import StarryCore
import SwiftUI

/// Thrown instead of an address by a source with nothing to play (and in place of a missing
/// resolver): the player runs a simulated clock. A real source's `notImplemented` is an error like any other.
struct SimulatedPlayback: Error {}

/// Queue and playback state, with a simulated clock for offline sources.
/// Commit track switches only after resolution succeeds; failures keep the current song.
@MainActor
@Observable
final class PlayerController {
    let engine = AVDeckEngine()

    private(set) var queue: [Track] = []
    /// Position of `current` in `queue`; nil when nothing plays or the playing song was removed
    /// from the queue.
    private(set) var index: Int?
    private(set) var current: Track?
    /// +1 for next, −1 for previous, 0 for a direct selection.
    private(set) var switchDirection = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// Volume slider position, 0…1; 0 is muted. The engine gets `VolumeCurve.gain(forLevel:)`.
    private(set) var volume: Double = 0.8
    private var volumeBeforeMute: Double = 0.8
    var repeatMode: RepeatMode = .off {
        didSet { if repeatMode != oldValue { syncUpcoming() } }
    }
    var shuffle = false {
        didSet { if shuffle != oldValue { syncUpcoming() } }
    }
    /// Personal FM's own loop (repeat one when on, endless when off), which an endless queue follows
    /// instead of `repeatMode`; every new endless queue starts with it off.
    private(set) var endlessRepeatsOne = false
    var liked: Set<TrackRef> = []
    var context: PlaybackContext?
    var showNowPlaying = false {
        didSet { if showNowPlaying { nowPlayingMounted = true } }
    }
    var nowPlayingMounted = false
    private(set) var lyrics: LyricsDocument?
    /// Where `lyrics` came from: a provider's name, `AMLL TTML DB`, a file name, ….
    private(set) var lyricsOrigin: LyricsOrigin?
    private(set) var lyricsLoading = false
    /// Seconds the lyrics are shown later than their timing says (`+` later, `−` earlier), for
    /// this song and these lyrics; set by hand or by calibration, and remembered.
    private(set) var lyricOffset: TimeInterval = 0
    private(set) var lyricCalibration: LyricCalibrationState = .idle
    private(set) var accentColor: Color?
    private(set) var coverImage: NSImage?
    private(set) var currentAsset: PlayableAsset?

    var spatialMixName: String {
        guard let tier = currentAsset?.tier, tier.isSpatial else { return "空间音频" }
        return tier.name
    }
    var isSeeking = false
    /// Bumped by every seek, so a display that does not watch the clock (the menu bar's plain
    /// lyrics) can follow jumps of the position.
    private(set) var seekSerial = 0
    var preloadsNext = true
    var transitions = AppSettings.Transition() {
        didSet {
            guard transitions != oldValue else { return }
            engine.transitionMode = transitions.mode()
            if let upcoming, upcoming.armed {
                if engine.armedTrack == upcoming.request.track.id { engine.cancelArmed() }
                self.upcoming?.armed = false
            }
            preloadNextIfNeeded()
        }
    }
    private(set) var vocalAttenuationEnabled = false
    private(set) var vocalLevel: Double = VocalAttenuationCurve.defaultLevel
    /// What the engine reports for the playing song (active, preparing, unavailable, model).
    private(set) var vocalStatus = VocalAttenuationStatus()
    /// The equalizer, kept across launches like the volume. Not in the settings store: a band dragged
    /// changes it many times a second, and every view reading the settings would re-render.
    private(set) var equalizer = EqualizerSettings()

    var rate: Double { isPlaying ? 1 : 0 }

    var shellTime: TimeInterval { showNowPlaying ? _currentTime : currentTime }

    /// Per-frame clock: use engine time, or `currentTime` during simulation, scrubbing and seeks.
    /// Display-link reads do not create a SwiftUI dependency.
    func preciseClock() -> (time: TimeInterval, rate: Double) {
        guard usingEngine, !isSeeking, pendingSeek == nil, _current != nil else { return (currentTime, rate) }
        return (engine.currentTime, Double(engine.rate))
    }

    /// The spectrum's bands (40 Hz…16 kHz, log-spaced, 0…1) for the equalizer's graph; empty
    /// while nothing plays. Like `energies()`, it is of what is heard as the frame shows
    /// (`AVDeckEngine.audibleSnapshot`). The simulated clock shapes a moving one from the same
    /// pulse as `energies()`.
    func spectrumBands() -> [Float] {
        if usingEngine { return engine.audibleSnapshot(lead: Self.displayLead).bands }
        guard isPlaying else { return [] }
        let beat = Float(max(0, sin(currentTime * 2 * .pi * 2)))
        let t = Float(currentTime)
        return (0..<48).map { band in
            let x = Float(band) / 47
            let tilt = 0.66 - 0.34 * x
            let kick = 0.22 * beat * beat * exp(-Float(band) / 7)
            let shimmer = 0.05 * sin(t * 3.1 + Float(band) * 0.55) + 0.04 * sin(t * 5.3 - Float(band) * 0.9)
            return min(max(tilt + kick + shimmer, 0), 1)
        }
    }

    /// About how long a frame drawn from the spectrum takes to show.
    static let displayLead: TimeInterval = 0.025

    /// The spectrum of what is heard `lead` seconds from now, for bars that move with the sound
    /// (`AVDeckEngine.audibleSpectrum`): unsmoothed, each band the loudest since `after` (the
    /// previous call's `time`). The simulated clock gives `spectrumBands()`.
    func audibleSpectrum(lead: TimeInterval, after: TimeInterval?) -> (bands: [Float], time: TimeInterval) {
        if usingEngine { return engine.audibleSpectrum(lead: lead, after: after) }
        return (spectrumBands(), currentTime)
    }

    /// Low, mid and high energy and the overall level of what is heard as the frame shows, for
    /// the Now Playing backdrop and the heart's beat.
    func energies() -> SIMD4<Float> {
        if usingEngine {
            let s = engine.audibleSnapshot(lead: Self.displayLead, bands: false)
            return SIMD4(s.low, s.mid, s.high, s.overall)
        }
        guard isPlaying else { return SIMD4(repeating: 0) }
        let beat = Float(max(0, sin(currentTime * 2 * .pi * 2)))
        return SIMD4(0.55 * beat * beat, 0.3 * beat, 0.2 * beat, 0.4 * beat)
    }

    // Injected by AppModel.
    /// The song's address, at this tier or (nil) the one asked for by default (`AppModel.requestedTier`).
    var resolveAsset: ((Track, QualityTier?) async throws -> PlayableAsset)?
    var loadLyrics: ((Track) -> AsyncStream<ResolvedLyrics>)?
    var prefetchLyrics: ((Track) async -> Void)?
    var onTrackStarted: ((Track) -> Void)?
    var onMessage: ((String) -> Void)?
    var reportPlayback: ((PlaybackReport) -> Void)?
    var keepDownload: ((Track, PlayableAsset, URL) -> Void)?
    var refillQueue: ((PlaybackContext, [Track]) async throws -> [Track])?
    /// Next skipped a song of an endless queue after this many seconds (personal FM learns from it).
    var onEndlessSkip: ((Track, TimeInterval) -> Void)?

    private var simulatedClock: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var lyricsPrefetched: TrackRef?
    private var generation = 0
    /// Bumped when another song becomes `current`; lyrics and cover lookups for older songs are
    /// dropped. Separate from `generation` so a switch still in flight (which may fail) does not
    /// cut off the current song's lookups.
    private var trackGeneration = 0
    private var usingEngine = false
    private var pending: PendingLoad?
    private var upcoming: Upcoming?
    private var preloadTask: Task<Void, Never>?
    private var preloadSerial = 0
    /// The latest seek handed to the engine and not yet landed. Right after `AVPlayer.seek` the
    /// periodic observer still reports the old position, which would snap the progress back.
    private var pendingSeek: Int?
    private var seekCount = 0
    @ObservationIgnored private(set) var systemMediaControls: SystemMediaControls?
    @ObservationIgnored var lyricOffsets = LyricOffsetStore(directory: nil)
    private var calibrationTask: Task<Void, Never>?
    private var awaitsAddress = false

    private static let volumeKey = "starry.volume"
    private static let volumeBeforeMuteKey = "starry.volumeBeforeMute"
    private static let vocalLevelKey = "starry.vocalLevel"
    private static let equalizerKey = "starry.equalizer"

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.object(forKey: Self.volumeKey) as? Double { volume = min(max(saved, 0), 1) }
        if let saved = defaults.object(forKey: Self.volumeBeforeMuteKey) as? Double, saved > 0 { volumeBeforeMute = min(saved, 1) }
        engine.volume = VolumeCurve.gain(forLevel: volume)
        if let saved = defaults.object(forKey: Self.vocalLevelKey) as? Double { vocalLevel = VocalAttenuationCurve.clamp(saved) }
        engine.vocalLevel = vocalLevel
        if let data = defaults.data(forKey: Self.equalizerKey), let saved = try? JSONDecoder().decode(EqualizerSettings.self, from: data) { equalizer = saved }
        engine.equalizer = equalizer
        eventTask = Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
        systemMediaControls = SystemMediaControls(player: self)
    }

    /// Plays `tracks` as the new queue. `startAt` names the song the user picked: if it cannot
    /// play, nothing changes. Without it the queue starts from the top, skipping songs that
    /// cannot play.
    func play(_ tracks: [Track], startAt start: Int? = nil, context: PlaybackContext? = nil) {
        guard !tracks.isEmpty else { return }
        let position = min(max(start ?? 0, 0), tracks.count - 1)
        load(PendingLoad(queue: tracks, index: position, track: tracks[position], context: context, autoplay: true, skip: start == nil ? 1 : nil))
    }

    /// Plays `tracks` as the new queue with shuffle on, from a random song (moving on at random
    /// past songs that cannot play).
    func shufflePlay(_ tracks: [Track], context: PlaybackContext? = nil) {
        guard !tracks.isEmpty else { return }
        shuffle = true
        let position = Int.random(in: 0..<tracks.count)
        load(PendingLoad(queue: tracks, index: position, track: tracks[position], context: context, autoplay: true, skip: 1))
    }

    /// Plays `track` now: where it already sits in the queue, else right after the current song.
    /// If it cannot play, nothing changes.
    func play(_ track: Track, context: PlaybackContext? = nil) {
        let position = queue.firstIndex(of: track) ?? (index ?? -1) + 1
        load(PendingLoad(queue: nil, index: position, track: track, context: context, autoplay: true, skip: nil))
    }

    func playNext(_ track: Track) { playNext([track]) }

    func playNext(_ tracks: [Track]) {
        var seen: Set<TrackRef> = current.map { [$0.id] } ?? []
        let incoming = tracks.filter { seen.insert($0.id).inserted }
        guard !incoming.isEmpty else { return }
        let moving = Set(incoming.map(\.id))
        var kept: [Track] = []
        kept.reserveCapacity(queue.count + incoming.count)
        var position = index
        for (offset, track) in queue.enumerated() {
            if !moving.contains(track.id) {
                kept.append(track)
            } else if let current = position, let index, offset < index {
                position = current - 1
            }
        }
        kept.insert(contentsOf: incoming, at: (position ?? -1) + 1)
        queue = kept
        index = position
        syncUpcoming()
    }

    func addToQueue(_ track: Track) { addToQueue([track]) }

    /// Appends the songs of `tracks` that are not queued yet, in one change of the queue.
    func addToQueue(_ tracks: [Track]) {
        var queued = Set(queue.map(\.id))
        let added = tracks.filter { queued.insert($0.id).inserted }
        guard !added.isEmpty else { return }
        queue += added
        if current == nil, pending == nil {
            load(PendingLoad(queue: nil, index: 0, track: queue[0], context: nil, autoplay: false, skip: nil))
        }
        syncUpcoming()
    }

    func extendQueue(_ tracks: [Track], from context: PlaybackContext) {
        if var pending, let pendingQueue = pending.queue {
            guard pending.context.map({ Self.sameOrigin($0, context) }) == true else { return }
            var queued = Set(pendingQueue.map(\.id))
            pending.queue = pendingQueue + tracks.filter { queued.insert($0.id).inserted }
            self.pending = pending
            return
        }
        guard isQueue(from: context) else { return }
        addToQueue(tracks)
    }

    func isQueue(from context: PlaybackContext) -> Bool {
        guard current != nil, let queue = self.context else { return false }
        return Self.sameOrigin(queue, context)
    }

    private static func sameOrigin(_ a: PlaybackContext, _ b: PlaybackContext) -> Bool {
        a.source == b.source && a.originType == b.originType && a.originID == b.originID
    }

    func remove(_ track: Track) { remove(track, autoplay: isPlaying) }

    func dropCurrent() {
        guard let current else { return }
        remove(current, autoplay: true)
    }

    private func remove(_ track: Track, autoplay: Bool) {
        guard let position = queue.firstIndex(of: track) else { return }
        queue.remove(at: position)
        defer { syncUpcoming() }
        guard let index else { return }
        if position < index {
            self.index = index - 1
        } else if position == index {
            if isEndless, position == queue.count {
                self.index = nil
                awaitRefill(from: PendingLoad(queue: nil, index: position - 1, track: track, context: nil, autoplay: autoplay, skip: 1), autoplay: autoplay)
                return
            }
            guard !queue.isEmpty else { stop(); return }
            self.index = nil
            let next = min(position, queue.count - 1)
            load(PendingLoad(queue: nil, index: next, track: queue[next], context: nil, autoplay: autoplay, skip: 1))
        }
    }

    func clearQueue() {
        stop()
        queue.removeAll()
    }

    func reloadCurrent(tier: QualityTier) {
        guard let current, let index, usingEngine || awaitsAddress else { return }
        awaitsAddress = false
        load(PendingLoad(queue: nil, index: index, track: current, context: nil, autoplay: isPlaying, skip: nil, inPlace: true, tier: tier))
    }

    /// Opens `snapshot` as it was left: queue, song, position, repeat and shuffle, paused. Only
    /// the song's details load (cover, lyrics); its address is looked up on the first play, so
    /// launching costs no stream request and an expired address never matters.
    func restore(_ snapshot: PlaybackSnapshot) {
        guard current == nil, pending == nil, let track = snapshot.current else { return }
        repeatMode = snapshot.repeatMode
        shuffle = snapshot.shuffle
        commit(PendingLoad(queue: snapshot.queue, index: snapshot.index, track: track, context: snapshot.context, autoplay: false, skip: nil))
        let length = track.duration > 0 ? track.duration : .infinity
        // A song left in its last seconds opens at its start.
        let position = snapshot.position < length - 5 ? snapshot.position : 0
        currentTime = position
        awaitsAddress = true
        systemMediaControls?.update()
    }

    /// What `restore` needs to reopen the queue later; nil when nothing is queued.
    func snapshot() -> PlaybackSnapshot? {
        guard let index, queue.indices.contains(index) else { return nil }
        return PlaybackSnapshot(queue: queue, index: index, position: currentTime, context: context, repeatMode: repeatMode, shuffle: shuffle)
    }

    func togglePlayPause() {
        guard current != nil else { return }
        isPlaying ? pause() : resume()
    }

    func next() {
        // Personal FM learns from the songs skipped (not from those that end, or a switch in flight).
        if isEndless, pending == nil, refillCursor == nil, let current { onEndlessSkip?(current, currentTime) }
        advance()
    }

    private func advance() {
        guard let from = cursor else { return }
        if pending == nil, refillCursor == nil, let upcoming, !upcoming.failed, isFollowing(upcoming) {
            var request = upcoming.request
            request.autoplay = true
            if let failure = upcoming.failure { onMessage?(failure) }
            load(request)
        } else if var request = stepping(from, by: 1) {
            request.autoplay = true
            load(request)
        } else if Self.isEndless(context(after: from)) {
            awaitRefill(from: from, autoplay: true)
        } else if pending == nil {
            pause()
            seek(to: duration)
        }
    }

    func previous() {
        if refillCursor != nil {
            refillCursor = nil
            isLoading = pending != nil
        }
        guard let from = cursor else { return }
        if pending == nil, currentTime > 3 { seek(to: 0); return }
        if var request = stepping(from, by: -1) {
            request.autoplay = true
            load(request)
        } else if pending == nil {
            seek(to: 0)
        }
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        let target = min(max(0, time), duration)
        currentTime = target
        seekSerial += 1
        systemMediaControls?.update()
        guard usingEngine else { return }
        seekCount += 1
        let id = seekCount
        pendingSeek = id
        Task {
            await engine.seek(to: target)
            if pendingSeek == id { pendingSeek = nil }
        }
    }

    func stop() {
        endPlaySession()
        generation += 1
        trackGeneration += 1
        loadTask?.cancel()
        simulatedClock?.cancel()
        preloadTask?.cancel()
        preloadTask = nil
        upcoming = nil
        lyricsTask?.cancel()
        cancelRefill()
        lyricsLoading = false
        engine.stop()
        pending = nil
        awaitsAddress = false
        current = nil
        index = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        setLyrics(nil, origin: nil)
        accentColor = nil
        coverImage = nil
        currentAsset = nil
        finishedDownload = nil
        systemMediaControls?.update()
    }

    func setLiked(_ track: Track, _ liked: Bool) {
        if liked { self.liked.insert(track.id) } else { self.liked.remove(track.id) }
    }

    func isLiked(_ track: Track) -> Bool { liked.contains(track.id) }

    var isMuted: Bool { volume == 0 }

    func setVolume(_ level: Double) {
        let level = min(max(level, 0), 1)
        guard level != volume else { return }
        volume = level
        engine.volume = VolumeCurve.gain(forLevel: level)
        UserDefaults.standard.set(level, forKey: Self.volumeKey)
    }

    func stepVolume(up: Bool) {
        let step = 0.05
        setVolume(((volume / step).rounded() + (up ? 1 : -1)) * step)
    }

    func toggleMute() {
        if isMuted {
            setVolume(volumeBeforeMute)
        } else {
            volumeBeforeMute = volume
            UserDefaults.standard.set(volume, forKey: Self.volumeBeforeMuteKey)
            setVolume(0)
        }
    }

    /// Turns sing mode on or off. While the vocals cannot be controlled the reason is shown; Low Power
    /// Mode and thermal pressure keep the switch off, a song that cannot be processed only affects
    /// itself, so the switch still applies to the songs after it.
    func setVocalAttenuation(_ enabled: Bool) {
        guard enabled != vocalAttenuationEnabled else { return }
        if enabled, let reason = vocalStatus.unavailable {
            onMessage?(reason.message(spatialMix: spatialMixName))
            guard reason == .unsupportedSource || reason == .spatialMix || reason == .performance else { return }
        }
        vocalAttenuationEnabled = enabled
        engine.vocalAttenuationEnabled = enabled
    }

    func toggleVocalAttenuation() {
        setVocalAttenuation(!vocalAttenuationEnabled)
    }

    /// Vocal level 5…100: 100 is the original mix, 5 leaves the voice at 5 % (−26 dB).
    func setVocalLevel(_ level: Double) {
        let level = VocalAttenuationCurve.clamp(level)
        guard level != vocalLevel else { return }
        vocalLevel = level
        engine.vocalLevel = level
        UserDefaults.standard.set(level, forKey: Self.vocalLevelKey)
    }

    func stepVocalLevel(up: Bool) {
        setVocalLevel(((vocalLevel / 5).rounded() + (up ? 1 : -1)) * 5)
    }

    func updateEqualizer(_ change: (inout EqualizerSettings) -> Void) {
        var settings = equalizer
        change(&settings)
        guard settings != equalizer else { return }
        equalizer = settings
        engine.equalizer = settings
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.equalizerKey) }
    }

    func setEqualizerEnabled(_ enabled: Bool) {
        updateEqualizer { $0.isEnabled = enabled }
    }

    func selectEqualizerPreset(_ id: String) {
        updateEqualizer {
            if id == EqualizerPreset.customID {
                $0.selectCustom()
            } else if let preset = EqualizerPreset.preset(id: id) {
                $0.select(preset)
            }
            $0.isEnabled = true
        }
    }

    func setEqualizerGain(_ gain: Double, band: Int) {
        updateEqualizer {
            $0.setGain(gain, at: band)
            $0.isEnabled = true
        }
    }

    func setEqualizerMode(_ mode: EqualizerMode) {
        updateEqualizer {
            $0.setMode(mode)
            $0.isEnabled = true
        }
    }

    func updateEqualizerBand(slot: Int, _ change: (inout ParametricBand) -> Void) {
        updateEqualizer {
            $0.updateBand(slot: slot, change)
            $0.isEnabled = true
        }
    }

    /// The slot the band went into; nil when all are taken.
    @discardableResult
    func addEqualizerBand(_ band: ParametricBand) -> Int? {
        var slot: Int?
        updateEqualizer {
            slot = $0.addBand(band)
            $0.isEnabled = true
        }
        return slot
    }

    func removeEqualizerBand(slot: Int) {
        updateEqualizer { $0.removeBand(slot: slot) }
    }

    func importEqualizer(_ profile: EqualizerAPOText.Profile, name: String) {
        updateEqualizer {
            $0.setParametric(profile, name: name)
            $0.isEnabled = true
        }
    }

    func cycleRepeat() {
        if isEndless {
            endlessRepeatsOne.toggle()
            syncUpcoming()
            return
        }
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    private struct PendingLoad {
        /// Replaces the queue when the switch lands (`play(_:startAt:context:)`); nil keeps the
        /// live queue, where `track` is looked up again at that point.
        var queue: [Track]?
        var index: Int
        var track: Track
        var context: PlaybackContext?
        var autoplay: Bool
        /// Where to look when `track` cannot play: the next (+1) or previous (−1) song. Nil for
        /// a song the user picked, whose failure just leaves the current song playing.
        var skip: Int?
        /// Songs skipped so far in this run because they could not play.
        var failures = 0
        var inPlace = false
        /// This tier instead of the one asked for by default (a song switched to another quality
        /// in place).
        var tier: QualityTier?
    }

    /// Where next / previous count from: a switch still in flight (so pressing next twice skips
    /// two songs), the end of an endless queue waiting for its refill, else the current song.
    private var cursor: PendingLoad? {
        if let pending { return pending }
        if let refillCursor { return refillCursor }
        guard let index, queue.indices.contains(index) else { return nil }
        return PendingLoad(queue: nil, index: index, track: queue[index], context: nil, autoplay: isPlaying, skip: nil)
    }

    private func context(after request: PendingLoad) -> PlaybackContext? {
        request.queue != nil ? request.context : request.context ?? context
    }

    /// The switch `step` songs away from `from` in its queue (forward picks at random on
    /// shuffle; repeat-all wraps around; an endless queue does neither), or nil past either end.
    private func stepping(_ from: PendingLoad, by step: Int) -> PendingLoad? {
        let tracks = from.queue ?? queue
        guard !tracks.isEmpty else { return nil }
        let endless = Self.isEndless(context(after: from))
        var position = from.index + step
        if shuffle, !endless, step > 0 {
            position = Int.random(in: 0..<tracks.count)
        } else if !tracks.indices.contains(position) {
            guard repeatMode == .all, !endless else { return nil }
            position = (position % tracks.count + tracks.count) % tracks.count
        }
        var request = from
        request.index = position
        request.track = tracks[position]
        request.skip = step
        request.failures = 0
        return request
    }

    /// Resolves `request.track`'s address, then makes it the current song (`commit`). Until
    /// then the engine and everything the UI shows stay on the current song; if it cannot play,
    /// they stay there for good, or the switch moves on per `request.skip`.
    private func load(_ request: PendingLoad) {
        generation += 1
        let gen = generation
        loadTask?.cancel()
        preloadTask?.cancel()
        // The armed song must not take over while this switch looks for its address (it would
        // land on top of it); armed again once the switch is done (or failed).
        if engine.armedTrack != nil { engine.cancelArmed() }
        pending = request
        isLoading = true
        refillCursor = nil
        refillIfNearEnd(request)
        let track = request.track

        loadTask = Task {
            defer { systemMediaControls?.update() }
            do {
                let asset: PlayableAsset
                if request.tier == nil, let known = upcoming?.asset, upcoming?.request.track.id == track.id, !known.isExpired() {
                    asset = known
                } else {
                    guard let resolveAsset else { throw SimulatedPlayback() }
                    asset = try await resolveAsset(track, request.tier)
                }
                guard gen == generation, !Task.isCancelled else { return }
                if upcoming?.request.track.id == track.id { upcoming = nil }
                let request = pending ?? request
                var startAt: TimeInterval?
                if request.inPlace {
                    pending = nil
                    isLoading = false
                    startAt = currentTime > 0 ? currentTime : nil
                } else {
                    commit(request)
                }
                currentAsset = asset
                usingEngine = true
                isPlaying = request.autoplay
                NSLog("[player] load %@ ← %@ (%@, %@, %@)", track.title, asset.url.host ?? "file", asset.provider.rawValue, asset.container.rawValue, asset.tier.id)
                try await engine.load(asset, track: track.id, autoplay: false, startAt: startAt)
                guard gen == generation, !Task.isCancelled else { return }
                if isPlaying { engine.play() } else { engine.pause(fade: false) }
                // Another quality of the same play is not a new play.
                if request.tier == nil { onTrackStarted?(track) }
                if asset.isTrial { onMessage?("当前为 30 秒试听片段") }
            } catch is SimulatedPlayback {
                guard gen == generation else { return }
                let request = pending ?? request
                if request.inPlace {
                    pending = nil
                    isLoading = false
                } else {
                    commit(request)
                }
                usingEngine = false
                onTrackStarted?(track)
                if request.autoplay { resume() } else { pause() }
            } catch is CancellationError {
            } catch {
                guard gen == generation else { return }
                NSLog("[player] failed %@: %@", track.title, String(describing: error))
                onMessage?("《\(track.title)》\(ErrorText.describe(error))")
                let request = pending ?? request
                let endless = Self.isEndless(context(after: request))
                let failures = request.failures + 1
                // Skipping on never wraps around an endless queue, so its length sets no limit.
                if request.autoplay, let step = request.skip, failures < (endless ? 4 : min(4, (request.queue ?? queue).count)) {
                    if var following = stepping(request, by: step),
                       request.queue != nil || following.track != current {
                        following.failures = failures
                        try? await Task.sleep(for: .milliseconds(600))
                        guard gen == generation else { return }
                        following.autoplay = pending?.autoplay ?? following.autoplay
                        load(following)
                        return
                    }
                    if endless, step > 0 {
                        pending = nil
                        awaitRefill(from: request, autoplay: request.autoplay)
                        return
                    }
                }
                pending = nil
                isLoading = false
                if request.inPlace, request.tier == nil { awaitsAddress = true }
                if usingEngine, engine.rate == 0 { isPlaying = false }
            }
        }
    }

    private func commit(_ request: PendingLoad) {
        endPlaySession()
        awaitsAddress = false
        pending = nil
        isLoading = false
        simulatedClock?.cancel()
        if let tracks = request.queue {
            queue = tracks
            index = request.index
            context = request.context
            if isEndless { endlessRepeatsOne = false }
        } else {
            if queue.indices.contains(request.index), queue[request.index] == request.track {
                index = request.index
            } else if let existing = queue.firstIndex(of: request.track) {
                index = existing
            } else {
                let position = (index ?? -1) + 1
                queue.insert(request.track, at: position)
                index = position
            }
            if let context = request.context { self.context = context }
        }
        if isEndless, let index, index > Self.endlessHistory {
            queue.removeFirst(index - Self.endlessHistory)
            self.index = Self.endlessHistory
        }
        refillsWithoutPlay = 0
        current = request.track
        switchDirection = request.skip ?? 0
        trackGeneration += 1
        pendingSeek = nil
        currentTime = 0
        duration = request.track.duration
        currentAsset = nil
        finishedDownload = nil
        updateAccent(for: request.track)
        startLyrics(for: request.track, keepingCurrent: false)
        beginPlaySession(for: request.track)
    }

    static let endlessHistory = 10

    /// Whether the queue refills itself instead of ending (personal FM): it plays in order with
    /// its own loop (`endlessRepeatsOne`), asks `refillQueue` for more when it reaches its last
    /// two songs, waits for them when it gets to the end first, and keeps `endlessHistory` played
    /// songs.
    var isEndless: Bool { Self.isEndless(context) }

    private static func isEndless(_ context: PlaybackContext?) -> Bool { context?.originType == .radio }

    var activeRepeat: RepeatMode { isEndless ? (endlessRepeatsOne ? .one : .off) : repeatMode }

    private var refillTask: Task<Void, Never>?
    private var refillSerial = 0
    private var refillCursor: PendingLoad?
    /// Refills asked for since a song last started: a queue whose new songs never play stops
    /// asking (and so does one that keeps getting nothing new).
    private var refillsWithoutPlay = 0

    private func refillIfNearEnd(_ request: PendingLoad) {
        let context = context(after: request)
        guard Self.isEndless(context), request.index >= (request.queue ?? queue).count - 2 else { return }
        refill(for: context)
    }

    private func awaitRefill(from: PendingLoad, autoplay: Bool) {
        var from = from
        from.autoplay = autoplay
        refillCursor = from
        isLoading = true
        refill(for: context(after: from))
    }

    private func refill(for context: PlaybackContext?) {
        guard refillTask == nil else { return }
        guard let context, Self.isEndless(context), let refillQueue, refillsWithoutPlay < 3 else {
            refillFailed(nil)
            return
        }
        refillsWithoutPlay += 1
        refillSerial += 1
        let serial = refillSerial
        let queued = refillCursor?.queue ?? pending?.queue ?? queue
        refillTask = Task {
            let result: Result<[Track], Error>
            do {
                result = .success(try await refillQueue(context, queued))
            } catch {
                result = .failure(error)
            }
            guard serial == refillSerial else { return }
            refillTask = nil
            switch result {
            case .success(let tracks): refillLanded(tracks, for: context)
            case .failure(let error):
                NSLog("[player] refill failed: %@", String(describing: error))
                refillFailed(error)
            }
        }
    }

    private func refillLanded(_ tracks: [Track], for context: PlaybackContext) {
        if var waiting = refillCursor, let waitingQueue = waiting.queue {
            // Waiting at the end of a queue that never started (its first songs all failed).
            var queued = Set(waitingQueue.map(\.id))
            waiting.queue = waitingQueue + tracks.filter { queued.insert($0.id).inserted }
            refillCursor = waiting
        } else {
            extendQueue(tracks, from: context)
        }
        guard let waiting = refillCursor else { return }
        if var request = stepping(waiting, by: 1) {
            refillCursor = nil
            request.autoplay = waiting.autoplay
            load(request)
        } else {
            refill(for: context)
        }
    }

    private func refillFailed(_ error: Error?) {
        guard refillCursor != nil else { return }
        refillCursor = nil
        if pending == nil { isLoading = false }
        onMessage?(error.map { "没能取到更多推荐：\(ErrorText.describe($0))" } ?? "暂时没有更多推荐")
        if duration > 0, currentTime + 0.5 >= duration {
            pause()
            seek(to: duration)
        }
    }

    private func cancelRefill() {
        refillSerial += 1
        refillTask?.cancel()
        refillTask = nil
        refillCursor = nil
    }

    /// The current song's finished download, waiting until the song has been heard long enough
    /// to keep: a song skipped after a few seconds does not push others out of the cache.
    private var finishedDownload: URL?
    /// Seconds heard before a song is kept (half of a shorter song).
    private static let keepAfter: TimeInterval = 20

    private func keepDownloadIfHeard() {
        guard let file = finishedDownload, let current, let asset = currentAsset,
              let session = playSession, session.track.id == current.id else { return }
        let length = current.duration > 0 ? current.duration : duration
        let needed = length > 0 ? min(Self.keepAfter, length / 2) : Self.keepAfter
        guard session.played >= needed else { return }
        finishedDownload = nil
        keepDownload?(current, asset, file)
    }

    /// How much of one play has actually been heard. Pauses, scrubbing and repeats all produce
    /// separate runs of the clock, so the heard seconds are summed from the engine's time
    /// observations rather than taken from wall time or the final position.
    private struct PlaySession {
        var track: Track
        var context: PlaybackContext?
        /// When audio first advanced; nil while the song sits loaded but unplayed.
        var startedAt: Date?
        var played: TimeInterval = 0
        var lastSample: TimeInterval?
    }

    private var playSession: PlaySession?

    /// A clock step longer than this is a seek or a stall, not listening.
    private static let maxPlayStep: TimeInterval = 2

    private func beginPlaySession(for track: Track) {
        playSession = PlaySession(track: track, context: context)
    }

    private func accumulatePlay(upTo sample: TimeInterval) {
        guard playSession != nil else { return }
        defer { playSession?.lastSample = sample }
        guard isPlaying, !isSeeking, pendingSeek == nil, let last = playSession?.lastSample else { return }
        let step = sample - last
        guard step > 0, step <= Self.maxPlayStep else { return }
        playSession?.played += step
        if playSession?.startedAt == nil { playSession?.startedAt = Date().addingTimeInterval(-step) }
    }

    /// Ends the current play, reporting it when it crossed the scrobble threshold. Idempotent, so
    /// the end of a song and the switch that follows it only report once. A play interrupted by
    /// quitting the app is never reported.
    private func endPlaySession() {
        guard let session = playSession else { return }
        playSession = nil
        guard let startedAt = session.startedAt else { return }
        let length = session.track.duration > 0 ? session.track.duration : duration
        guard length > 0, session.played >= PlaybackReport.scrobbleThreshold(duration: length) else { return }
        reportPlayback?(PlaybackReport(
            track: session.track.id, context: session.context, playedSeconds: session.played,
            duration: length, startedAt: startedAt, endedAt: Date()
        ))
    }

    func resume() {
        pending?.autoplay = true
        refillCursor?.autoplay = true
        guard let current else { return }
        if awaitsAddress, pending == nil, let index {
            awaitsAddress = false
            load(PendingLoad(queue: nil, index: index, track: current, context: nil, autoplay: true, skip: nil, inPlace: true))
            return
        }
        isPlaying = true
        if usingEngine { engine.play() } else { startSimulatedClock() }
        systemMediaControls?.update()
    }

    func pause() {
        pending?.autoplay = false
        refillCursor?.autoplay = false
        guard current != nil, isPlaying else { return }
        isPlaying = false
        if usingEngine { engine.pause(fade: true) } else { simulatedClock?.cancel() }
        systemMediaControls?.update()
    }

    private func startSimulatedClock() {
        simulatedClock?.cancel()
        simulatedClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                guard !isSeeking else { continue }
                if currentTime + 0.1 >= duration {
                    if activeRepeat == .one { currentTime = 0 } else if pending == nil, refillCursor == nil { advance() }
                } else {
                    currentTime += 0.1
                }
                systemMediaControls?.update(force: false)
            }
        }
    }

    private var engineFailures = 0

    private func handle(_ event: PlaybackEvent) {
        defer { systemMediaControls?.update(force: false) }
        switch event {
        case .time(let t):
            if !isSeeking, pendingSeek == nil { currentTime = t }
            if t > 1 { engineFailures = 0 }
            accumulatePlay(upTo: t)
            keepDownloadIfHeard()
            preloadNextIfNeeded()
        case .duration(let d): if d > 0 { duration = d }
        case .rate(let r): isPlaying = r > 0
        case .vocalAttenuation(let status): vocalStatus = status
        case .downloadFinished(let track, let file):
            // Songs from a source (not a file or the cache already, not a trial excerpt).
            guard track == current?.id, let asset = currentAsset, asset.provider == .source, !asset.isTrial else { break }
            finishedDownload = file
            keepDownloadIfHeard()
        case .transitionPivoted(let track):
            takeOver(track)
        case .playbackEnded:
            keepDownloadIfHeard()
            endPlaySession()
            if activeRepeat == .one {
                seek(to: 0)
                resume()
                if let current { beginPlaySession(for: current) }
            } else if pending == nil, refillCursor == nil {
                advance()
            }
        case .error(let error):
            endPlaySession()
            NSLog("[player] engine error: %@", String(describing: error))
            onMessage?(ErrorText.describe(error))
            // A local file that does not decode will not later either: on to the next song, a
            // few times at most (a folder of such files does not spin through the queue).
            if currentAsset?.provider == .local, engineFailures < 3 {
                engineFailures += 1
                advance()
            } else {
                pause()
            }
        default: break
        }
    }

    func reloadLyrics() {
        guard let current else { return }
        startLyrics(for: current, keepingCurrent: true)
    }

    func useLyrics(_ resolved: ResolvedLyrics) {
        lyricsTask?.cancel()
        lyricsLoading = false
        setLyrics(resolved.document, origin: resolved.origin)
    }

    private func startLyrics(for track: Track, keepingCurrent: Bool) {
        lyricsTask?.cancel()
        if !keepingCurrent { setLyrics(nil, origin: nil) }
        guard let stream = loadLyrics?(track) else {
            lyricsLoading = false
            return
        }
        lyricsLoading = true
        let gen = trackGeneration
        lyricsTask = Task { [weak self] in
            var found = false
            for await result in stream {
                guard let self, gen == self.trackGeneration, !Task.isCancelled else { return }
                found = true
                self.setLyrics(result.document, origin: result.origin)
            }
            guard let self, gen == self.trackGeneration, !Task.isCancelled else { return }
            self.lyricsLoading = false
            if !found { self.setLyrics(nil, origin: nil) }
        }
    }

    private func setLyrics(_ document: LyricsDocument?, origin: LyricsOrigin?) {
        lyrics = document
        lyricsOrigin = origin
        let key = lyricOffsetKey
        lyricOffset = key.flatMap { lyricOffsets.entry(for: $0)?.offset } ?? 0
        if case .running(let running) = lyricCalibration, running != key { cancelLyricCalibration() }
    }

    private var lyricOffsetKey: String? {
        guard let current, let lyrics, !lyrics.isEmpty else { return nil }
        return LyricOffsetStore.key(track: current.id, lyrics: lyrics)
    }

    func setLyricOffset(_ offset: TimeInterval, calibrated: Bool = false) {
        let offset = min(max((offset * 100).rounded() / 100, -30), 30)
        lyricOffset = offset
        if let key = lyricOffsetKey { lyricOffsets.set(offset, calibrated: calibrated, for: key) }
    }

    func calibrateLyrics() {
        if lyricCalibration.isRunning { cancelLyricCalibration(); return }
        guard let key = lyricOffsetKey, let track = current, let document = lyrics else { return }
        guard usingEngine, let asset = currentAsset else { onMessage?("当前歌曲无法校准歌词"); return }
        guard !asset.isTrial else { onMessage?("试听片段无法校准歌词"); return }
        let model = engine.vocalModel
        lyricCalibration = .running(key: key)
        calibrationTask = Task { [weak self] in
            let started = Date()
            do {
                let file = try await LyricCalibrationAudio.file(for: asset)
                defer { if file.isTemporary { try? FileManager.default.removeItem(at: file.url) } }
                let fetched = Date()
                let result = try await LyricCalibrationAudio.calibrate(file, document: document, model: model)
                guard let self, !Task.isCancelled, self.lyricOffsetKey == key else { return }
                self.lyricCalibration = .idle
                let estimate = result.estimate.map { String(format: "%@ %+.3f s (z %.1f, peak ratio %.2f)", $0.method.rawValue, $0.offset, $0.score, $0.peakRatio) } ?? "none"
                NSLog("[calibrate] %@: %@ → %@; %d windows, separated %.0f of %.0f s with %@; download %.1f s, analysis %.1f s",
                      track.title, estimate, result.offset.map { String(format: "%+.2f s", $0) } ?? "not reliable (\(result.failure.map { "\($0)" } ?? "-"))",
                      result.windows.count, result.separatedDuration, result.songDuration, result.model?.name ?? "the mix",
                      fetched.timeIntervalSince(started), Date().timeIntervalSince(fetched))
                self.applyCalibration(result)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                if case .running(key) = self.lyricCalibration { self.lyricCalibration = .idle }
                NSLog("[calibrate] %@ failed: %@", track.title, String(describing: error))
                self.onMessage?(LyricCalibrationAudio.message(for: error))
            }
        }
    }

    func cancelLyricCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        lyricCalibration = .idle
    }

    private func applyCalibration(_ result: LyricsCalibration) {
        guard let offset = result.offset else {
            onMessage?(LyricCalibrationAudio.message(for: result.failure ?? .noClearMatch))
            return
        }
        if abs(offset) < 0.1 {
            setLyricOffset(0, calibrated: true)
            onMessage?("歌词时间准确，无需调整")
        } else {
            setLyricOffset(offset, calibrated: true)
            onMessage?(String(format: "已校准：歌词%@ %.2f 秒", offset > 0 ? "延后" : "提前", abs(offset)))
        }
    }

    /// The song the end of the current one plays, picked ahead (shuffle draws it here, so the
    /// song armed is the song that plays), with its address once resolved.
    private struct Upcoming {
        var after: TrackRef
        var request: PendingLoad
        var asset: PlayableAsset?
        var armed = false
        /// Songs passed over on the way to it because they cannot play (a VIP song), as a switch
        /// at the end would have; and what the last of them said.
        var skipped: [TrackRef] = []
        var failure: String?
        var failed = false
    }

    private var preloadLead: TimeInterval {
        max(30, (transitions.crossfade ? transitions.crossfadeSeconds : 0) + 20)
    }

    /// What the end of the current song switches to: the next song in order (drawn on shuffle),
    /// wrapping round on repeat-all; nil on repeat-one, past the end, and while another switch
    /// is in flight.
    private func nextRequest() -> PendingLoad? {
        guard pending == nil, refillCursor == nil, activeRepeat != .one, let from = cursor, var request = stepping(from, by: 1) else { return nil }
        request.autoplay = true
        return request
    }

    private func isFollowing(_ upcoming: Upcoming) -> Bool {
        guard let current, upcoming.after == current.id, var position = index, activeRepeat != .one,
              queue.indices.contains(upcoming.request.index), queue[upcoming.request.index].id == upcoming.request.track.id else { return false }
        if shuffle, !isEndless { return true }
        for expected in upcoming.skipped + [upcoming.request.track.id] {
            position += 1
            if position == queue.count, repeatMode == .all, !isEndless { position = 0 }
            guard queue.indices.contains(position), queue[position].id == expected else { return false }
        }
        return true
    }

    private func syncUpcoming() {
        guard let upcoming, !isFollowing(upcoming) else { return }
        dropUpcoming()
        preloadNextIfNeeded()
    }

    private func dropUpcoming() {
        preloadTask?.cancel()
        preloadTask = nil
        if let upcoming, engine.armedTrack == upcoming.request.track.id { engine.cancelArmed() }
        upcoming = nil
    }

    /// Picks the song that follows the current one and, `preloadLead` before the end, resolves
    /// its address and arms it in the engine (armed stage): with a transition the engine
    /// then starts it itself, otherwise the load at the end finds it ready.
    private func preloadNextIfNeeded() {
        guard preloadsNext || transitions.isEnabled, usingEngine, pending == nil, refillCursor == nil, duration > 0,
              currentTime > duration - preloadLead, preloadTask == nil, let current, let resolveAsset else { return }
        if let upcoming, !isFollowing(upcoming) { dropUpcoming() }
        if upcoming == nil {
            guard let request = nextRequest() else { return }
            upcoming = Upcoming(after: current.id, request: request)
        }
        guard let picked = upcoming, !picked.failed else { return }
        let next = picked.request.track
        if picked.armed, engine.armedTrack == next.id { return }
        upcoming?.armed = false
        guard next.id != current.id else { return }
        if let prefetchLyrics, lyricsPrefetched != next.id {
            lyricsPrefetched = next.id
            Task { await prefetchLyrics(next) }
        }
        let mode = transitions.mode(sameAlbum: Self.followOnAlbum(current, next))
        preloadSerial += 1
        let serial = preloadSerial
        preloadTask = Task {
            // A task cancelled and replaced must not clear its successor.
            defer { if preloadSerial == serial { preloadTask = nil } }
            let asset: PlayableAsset
            if let known = picked.asset, !known.isExpired() {
                asset = known
            } else {
                do {
                    asset = try await resolveAsset(next, nil)
                } catch {
                    guard !Task.isCancelled, var upcoming, upcoming.after == current.id, upcoming.request.track.id == next.id else { return }
                    NSLog("[player] next %@ cannot play: %@", next.title, String(describing: error))
                    // On to the song after it, as the switch at the end would go.
                    upcoming.skipped.append(next.id)
                    upcoming.failure = "《\(next.title)》\(ErrorText.describe(error))"
                    if upcoming.skipped.count < 3, var following = stepping(upcoming.request, by: 1), following.track.id != current.id {
                        following.autoplay = true
                        upcoming.request = following
                        upcoming.asset = nil
                    } else {
                        upcoming.failed = true
                    }
                    self.upcoming = upcoming
                    return
                }
            }
            guard !Task.isCancelled, upcoming?.after == current.id, upcoming?.request.track.id == next.id else { return }
            upcoming?.asset = asset
            guard await engine.arm(next: asset, track: next.id, mode: mode) else { return }
            if upcoming?.after == current.id, upcoming?.request.track.id == next.id {
                upcoming?.armed = true
            } else if engine.armedTrack == next.id {
                engine.cancelArmed()
            }
        }
    }

    private func takeOver(_ track: TrackRef) {
        guard let upcoming, upcoming.request.track.id == track, let asset = upcoming.asset else {
            NSLog("[player] engine took over with %@, not the song picked ahead", track.id)
            return
        }
        keepDownloadIfHeard()
        preloadTask?.cancel()
        preloadTask = nil
        self.upcoming = nil
        guard pending == nil else { return }
        var request = upcoming.request
        request.autoplay = true
        request.skip = 1
        refillIfNearEnd(request)
        commit(request)
        currentAsset = asset
        usingEngine = true
        isPlaying = true
        NSLog("[player] %@ %@ ← %@ (%@, %@, %@)", transitions.crossfade ? "crossfade" : "gapless", request.track.title, asset.url.host ?? "file", asset.provider.rawValue, asset.container.rawValue, asset.tier.id)
        if let failure = upcoming.failure { onMessage?(failure) }
        onTrackStarted?(request.track)
        if asset.isTrial { onMessage?("当前为 30 秒试听片段") }
        systemMediaControls?.update()
    }

    private static func followOnAlbum(_ a: Track, _ b: Track) -> Bool {
        guard a.id.source == b.id.source, let album = a.album?.id, !album.isEmpty, album == b.album?.id else { return false }
        guard let first = a.trackNumber, let second = b.trackNumber else { return true }
        let (discA, discB) = (a.discNumber ?? 1, b.discNumber ?? 1)
        return (discA == discB && second == first + 1) || (discB == discA + 1 && second == 1)
    }

    private func updateAccent(for track: Track) {
        coverImage = nil
        guard let artwork = track.artwork ?? track.album?.artwork else {
            withAnimation(Motion.accent) { accentColor = nil }
            return
        }
        guard let url = artwork.sized(300) else {
            withAnimation(Motion.accent) { accentColor = PlaceholderArt.accent(for: artwork.seed) }
            return
        }
        let gen = trackGeneration
        Task {
            let image = await ImageStore.shared.load(url, maxPixelSize: 300)
            guard gen == trackGeneration else { return }
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                // No cover after all: the placeholder art shows instead, so take its colour.
                withAnimation(Motion.accent) { accentColor = PlaceholderArt.accent(for: artwork.seed) }
                return
            }
            let palette = CoverPalette.extract(from: cg)
            let c = palette.accents.first ?? palette.dominant
            withAnimation(Motion.accent) {
                coverImage = image
                accentColor = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
            }
            systemMediaControls?.update()
        }
    }
}
