import Foundation
import MusicSources
import StarryCore

// Personal FM: a first few songs start an endless queue (`PlayerController.isEndless`), which
// asks for three more each time it reaches its last two and so never runs out; next tells the
// source the song was skipped, dislike drops it for good and plays the next one.
extension AppModel {
    static let personalFMName = "私人 FM"

    func playPersonalFM() {
        Task {
            do {
                let source = try require(browsingSourceID, as: (any RadioSource).self, "私人 FM")
                let tracks = try await Self.personalFMTracks(from: source, after: [], firstFetch: true)
                guard !tracks.isEmpty else { showToast("私人 FM 暂时没有推荐"); return }
                player.play(tracks, context: PlaybackContext(source: source.id, originType: .radio, originName: Self.personalFMName))
            } catch {
                showToast(ErrorText.describe(error))
            }
        }
    }

    /// Dislike: the next song plays and the source never recommends this one again.
    func trashPersonalFMTrack() {
        guard player.isEndless, let track = player.current,
              let source = self.source(track.id.source, as: (any RadioSource).self) else { return }
        let played = player.currentTime
        player.dropCurrent()
        Task {
            do {
                try await source.trashFM(track.id, playedSeconds: played)
            } catch {
                showToast(ErrorText.describe(error))
            }
        }
    }

    func wirePersonalFM() {
        player.refillQueue = { [weak self] context, queued in
            guard let id = context.source, let source = self?.source(id, as: (any RadioSource).self) else {
                throw SourceError.capabilityMissing("私人 FM")
            }
            return try await Self.personalFMTracks(from: source, after: queued, firstFetch: false)
        }
        player.onEndlessSkip = { [weak self] track, played in
            guard let source = self?.source(track.id.source, as: (any RadioSource).self) else { return }
            Task { try? await source.skipFM(track.id, playedSeconds: played) }
        }
    }

    /// The songs of one round of personal FM that are not queued yet, asking again when an answer
    /// brings fewer than three new ones.
    static func personalFMTracks(from source: any RadioSource, after queued: [Track], firstFetch: Bool) async throws -> [Track] {
        var seen = Set(queued.map(\.id))
        var found = try await source.personalFM(mode: .default, firstFetch: firstFetch).filter { seen.insert($0.id).inserted }
        if found.count < 3, let more = try? await source.personalFM(mode: .default, firstFetch: false) {
            found += more.filter { seen.insert($0.id).inserted }
        }
        return found
    }
}
