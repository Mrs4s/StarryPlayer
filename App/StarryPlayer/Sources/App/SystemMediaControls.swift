import AppKit
import MediaPlayer
import StarryCore

/// App-lifetime bridge between the queue controller and macOS / headset media controls.
@MainActor
final class SystemMediaControls: NSObject {
    enum Action: Sendable {
        case play, pause, togglePlayPause, next, previous, stop
        case seek(TimeInterval)
    }

    private weak var player: PlayerController?
    private let commands = MPRemoteCommandCenter.shared()
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkImage: NSImage?
    private var artwork: MPMediaItemArtwork?
    private var lastTrack: TrackRef?
    private var lastDuration: TimeInterval = 0
    private var lastPlaying = false
    private var lastUpdate = ContinuousClock.now
    private var isShutDown = false

    init(player: PlayerController) {
        self.player = player
        super.init()
        register(commands.playCommand, action: .play)
        register(commands.pauseCommand, action: .pause)
        register(commands.togglePlayPauseCommand, action: .togglePlayPause)
        register(commands.nextTrackCommand, action: .next)
        register(commands.previousTrackCommand, action: .previous)
        register(commands.stopCommand, action: .stop)
        let seekTarget = commands.changePlaybackPositionCommand.addTarget(handler: Self.seekHandler(self))
        targets.append((commands.changePlaybackPositionCommand, seekTarget))
        for command in [commands.seekForwardCommand, commands.seekBackwardCommand,
                        commands.skipForwardCommand, commands.skipBackwardCommand,
                        commands.changePlaybackRateCommand, commands.changeRepeatModeCommand,
                        commands.changeShuffleModeCommand, commands.likeCommand,
                        commands.dislikeCommand, commands.bookmarkCommand, commands.ratingCommand] {
            command.isEnabled = false
        }
        NotificationCenter.default.addObserver(self, selector: #selector(shutdown),
                                               name: NSApplication.willTerminateNotification, object: nil)
        update()
    }

    private func register(_ command: MPRemoteCommand, action: Action) {
        targets.append((command, command.addTarget(handler: Self.handler(self, action: action))))
    }

    // MediaPlayer may call these from its own queue. Create nonisolated closures and pass only
    // Sendable values to the main actor; never capture MPRemoteCommandEvent in a Task.
    nonisolated private static func handler(_ controls: SystemMediaControls, action: Action)
        -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak controls] _ in controls?.perform(action) ?? .commandFailed }
    }

    nonisolated private static func seekHandler(_ controls: SystemMediaControls)
        -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak controls] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  event.positionTime.isFinite else { return .commandFailed }
            return controls?.perform(.seek(event.positionTime)) ?? .commandFailed
        }
    }

    nonisolated func perform(_ action: Action) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { handle(action) }
        }
        return DispatchQueue.main.sync { self.handle(action) }
    }

    private func handle(_ action: Action) -> MPRemoteCommandHandlerStatus {
        guard !isShutDown, let player, player.current != nil else { return .noSuchContent }
        switch action {
        case .play: player.resume()
        case .pause: player.pause()
        case .togglePlayPause: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case .stop: player.stop()
        case .seek(let time):
            guard time.isFinite, player.duration > 0 else { return .commandFailed }
            player.seek(to: time)
        }
        return .success
    }

    /// Publish transitions immediately; macOS extrapolates the elapsed time between updates.
    /// Periodic corrections also stop its clock drifting when playback stalls.
    func update(force: Bool = true) {
        guard !isShutDown, let player else { return }
        let hasTrack = player.current != nil
        for (command, _) in targets { command.isEnabled = hasTrack }
        commands.changePlaybackPositionCommand.isEnabled = hasTrack && player.duration > 0
        guard let track = player.current else {
            infoCenter.playbackState = .stopped
            infoCenter.nowPlayingInfo = nil
            lastTrack = nil
            artworkImage = nil
            artwork = nil
            return
        }
        let artworkChanged = artworkImage !== player.coverImage
        guard force || lastTrack != track.id || lastDuration != player.duration ||
                lastPlaying != player.isPlaying || artworkChanged ||
                lastUpdate.duration(to: .now) >= .seconds(5) else { return }
        if artworkChanged {
            artworkImage = player.coverImage
            artwork = player.coverImage.map(Self.makeArtwork)
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistText,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.id.description,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if player.duration.isFinite, player.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
        }
        info[MPMediaItemPropertyAlbumTitle] = track.album?.name
        info[MPMediaItemPropertyArtwork] = artwork
        infoCenter.nowPlayingInfo = info
        // Required on macOS for the app to receive remote commands, independently of rate.
        infoCenter.playbackState = player.isPlaying ? .playing : .paused
        lastTrack = track.id
        lastDuration = player.duration
        lastPlaying = player.isPlaying
        lastUpdate = .now
    }

    nonisolated private static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    @objc func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets.removeAll()
        infoCenter.playbackState = .stopped
        infoCenter.nowPlayingInfo = nil
        NotificationCenter.default.removeObserver(self)
    }
}
