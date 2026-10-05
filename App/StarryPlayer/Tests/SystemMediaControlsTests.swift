import MediaPlayer
import StarryCore
import Testing
@testable import StarryPlayer

@Suite(.serialized)
@MainActor
struct SystemMediaControlsTests {
    private let first = Track(id: TrackRef(source: .local, id: "media-test-1"), title: "First",
                              artists: [ArtistRef(id: "artist", name: "Artist")],
                              album: AlbumRef(id: "album", name: "Album"), duration: 180)
    private let second = Track(id: TrackRef(source: .local, id: "media-test-2"), title: "Second", duration: 240)

    @Test func transportMetadataAndCleanup() async throws {
        let player = PlayerController()
        let controls = try #require(player.systemMediaControls)
        defer { player.stop(); controls.shutdown() }
        let infoCenter = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()

        #expect(controls.perform(.pause) == .noSuchContent)
        #expect(!commands.togglePlayPauseCommand.isEnabled)
        player.play([first, second])
        try await waitUntil { player.current == first && player.isPlaying }
        #expect(infoCenter.playbackState == .playing)
        #expect(infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "First")
        #expect(infoCenter.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == "Artist")
        #expect(infoCenter.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] as? String == "Album")
        #expect(commands.changePlaybackPositionCommand.isEnabled)

        let status = await Task.detached { controls.perform(.pause) }.value
        #expect(status == .success)
        #expect(controls.perform(.pause) == .success)
        #expect(!player.isPlaying)
        #expect(infoCenter.playbackState == .paused)
        #expect(infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(controls.perform(.seek(42)) == .success)
        #expect(player.currentTime == 42)
        #expect(infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42)
        #expect(controls.perform(.seek(.nan)) == .commandFailed)
        #expect(controls.perform(.play) == .success)
        #expect(controls.perform(.play) == .success)
        #expect(player.isPlaying)
        #expect(controls.perform(.togglePlayPause) == .success)
        #expect(!player.isPlaying)

        #expect(controls.perform(.next) == .success)
        try await waitUntil { player.current == second && player.isPlaying }
        #expect(infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Second")
        #expect(infoCenter.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] == nil)
        // Advancing a simulated song must restart its clock, too.
        try await waitUntil { player.currentTime > 0 }
        #expect(controls.perform(.previous) == .success)
        try await waitUntil { player.current == first }

        #expect(controls.perform(.stop) == .success)
        #expect(infoCenter.nowPlayingInfo == nil)
        #expect(infoCenter.playbackState == .stopped)
        #expect(!commands.playCommand.isEnabled)
        #expect(!commands.nextTrackCommand.isEnabled)
        controls.shutdown()
        #expect(controls.perform(.play) == .noSuchContent)
    }

    @Test func pauseWhileResolvingNextTrackSurvivesCommit() async throws {
        let player = PlayerController()
        let controls = try #require(player.systemMediaControls)
        var resolution: CheckedContinuation<PlayableAsset, Error>?
        defer { resolution?.resume(throwing: CancellationError()); player.stop(); controls.shutdown() }
        player.play([first, second])
        try await waitUntil { player.current == first && player.isPlaying }
        player.resolveAsset = { _, _ in
            try await withCheckedThrowingContinuation { resolution = $0 }
        }
        #expect(controls.perform(.next) == .success)
        try await waitUntil { resolution != nil }
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "First")
        #expect(controls.perform(.pause) == .success)
        resolution?.resume(throwing: SimulatedPlayback())
        resolution = nil
        try await waitUntil { player.current == second && !player.isLoading }
        #expect(!player.isPlaying)
        #expect(MPNowPlayingInfoCenter.default().playbackState == .paused)
        #expect(controls.perform(.play) == .success)
        try await waitUntil { player.currentTime > 0 }
    }

    @Test func failedSwitchKeepsCurrentMetadata() async throws {
        let player = PlayerController()
        let controls = try #require(player.systemMediaControls)
        defer { player.stop(); controls.shutdown() }
        player.play(first)
        try await waitUntil { player.current == first }
        player.resolveAsset = { _, _ in throw PlaybackError.decodeFailed("test failure") }
        player.play(second)
        try await waitUntil { !player.isLoading }
        #expect(player.current == first)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "First")
    }

    @Test func pauseDuringFailedTrackRetryIsPreserved() async throws {
        let player = PlayerController()
        let controls = try #require(player.systemMediaControls)
        defer { player.stop(); controls.shutdown() }
        let third = Track(id: TrackRef(source: .local, id: "media-test-3"), title: "Third", duration: 180)
        player.play([first, second, third])
        try await waitUntil { player.current == first && player.isPlaying }
        var failureReported = false
        player.onMessage = { _ in failureReported = true }
        player.resolveAsset = { track, _ in
            if track == second { throw PlaybackError.decodeFailed("test retry") }
            throw SimulatedPlayback()
        }
        #expect(controls.perform(.next) == .success)
        try await waitUntil { failureReported }
        #expect(player.isLoading)
        #expect(controls.perform(.pause) == .success)
        try await waitUntil { player.current == third }
        #expect(!player.isPlaying)
        #expect(MPNowPlayingInfoCenter.default().playbackState == .paused)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
