import Foundation
import StarryCore

/// Engine-facing contract. The engine knows only `PlayableAsset`s; sources never touch playback.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var events: AsyncStream<PlaybackEvent> { get }

    var currentTrack: TrackRef? { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var rate: Float { get }
    var volume: Float { get set }
    var transitionMode: TransitionMode { get set }

    func load(_ asset: PlayableAsset, track: TrackRef, autoplay: Bool, startAt: TimeInterval?) async throws
    /// Preload the next item into the idle deck (armed stage), to follow the current one
    /// with `mode` (the engine's `transitionMode` when nil). False when refused.
    @discardableResult
    func arm(next asset: PlayableAsset, track: TrackRef, mode: TransitionMode?) async -> Bool
    func cancelArmed()

    func play()
    func pause(fade: Bool)
    func stop()
    func seek(to time: TimeInterval) async
}

public extension PlaybackEngine {
    func load(_ asset: PlayableAsset, track: TrackRef, autoplay: Bool = true) async throws {
        try await load(asset, track: track, autoplay: autoplay, startAt: nil)
    }

    @discardableResult
    func arm(next asset: PlayableAsset, track: TrackRef) async -> Bool {
        await arm(next: asset, track: track, mode: nil)
    }
}
