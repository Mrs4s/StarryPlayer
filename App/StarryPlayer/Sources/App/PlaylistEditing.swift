import SwiftUI
import MusicSources
import StarryCore

struct PlaylistChange: Equatable {
    enum Kind: Equatable {
        /// Songs went in; where they land is the source's to say, so a page showing it loads it again.
        case added
        case removed(Set<TrackRef>)
        case edited
        case deleted
    }

    var playlist: Playlist
    var kind: Kind
    var serial: Int
}

struct PlaylistPulse: Equatable {
    var source: SourceID
    var id: String
    var serial: Int
}

struct PlaylistEditorRequest: Equatable {
    enum Purpose: Equatable {
        case create(adding: [Track])
        case edit(Playlist)
    }

    var source: SourceID
    var purpose: Purpose
}

extension AppModel {
    /// What `id` lets the account do with its playlists; nil when it edits none.
    func playlistEditing(of id: SourceID) -> PlaylistEditing? {
        source(id, as: (any PlaylistEditingSource).self)?.playlistEditing
    }

    func playlistsToAdd(of id: SourceID) -> [Playlist] {
        (playlistsBySource[id] ?? []).filter { $0.isOwned && $0.id != likedPlaylistIDs[id] }
    }

    /// The account's own playlist, not the liked list, its source's library open.
    private func isEditable(_ playlist: Playlist) -> Bool {
        playlist.isOwned && playlist.id != likedPlaylistIDs[playlist.source] && isLibraryOpen(playlist.source)
    }

    func canEdit(_ playlist: Playlist) -> Bool { isEditable(playlist) && playlistEditing(of: playlist.source)?.canEdit == true }
    func canDelete(_ playlist: Playlist) -> Bool { isEditable(playlist) && playlistEditing(of: playlist.source)?.canDelete == true }
    func canRemoveSongs(from playlist: Playlist) -> Bool { isEditable(playlist) && playlistEditing(of: playlist.source)?.canRemove == true }
    func canReorder(_ playlist: Playlist) -> Bool { isEditable(playlist) && playlistEditing(of: playlist.source)?.canReorder == true }

    func add(_ tracks: [Track], to playlist: Playlist) {
        let id = playlist.source
        let ids = tracks.filter { $0.id.source == id }.map(\.id.id)
        guard !ids.isEmpty else { return }
        guard isLibraryOpen(id) else { requestLogin(id); return }
        guard let source = source(id, as: (any PlaylistEditingSource).self) else { return }
        Task {
            do {
                let added = try await source.addTracks(ids, toPlaylist: playlist.id)
                tookSongs(playlist, added: added)
                showToast(Self.addedText(added, of: ids.count, to: playlist.name))
            } catch {
                showToast(ErrorText.describe(error))
            }
        }
    }

    static func addedText(_ added: Int, of count: Int, to name: String) -> String {
        if added == 0 { return count == 1 ? "这首歌已在「\(name)」中" : "这些歌都已在「\(name)」中" }
        if added == 1 && count == 1 { return "已加入「\(name)」" }
        return added < count ? "已加入 \(added) 首到「\(name)」，其余已在歌单中" : "已加入 \(added) 首到「\(name)」"
    }

    private func tookSongs(_ playlist: Playlist, added: Int) {
        var now = playlist
        updatePlaylists(of: playlist.source) { playlists in
            guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
            playlists[index].trackCount += added
            now = playlists[index]
        }
        playlistPulse = PlaylistPulse(source: playlist.source, id: playlist.id, serial: (playlistPulse?.serial ?? 0) + 1)
        if added > 0 { post(now, .added) }
    }

    private func post(_ playlist: Playlist, _ kind: PlaylistChange.Kind) {
        playlistChange = PlaylistChange(playlist: playlist, kind: kind, serial: (playlistChange?.serial ?? 0) + 1)
    }

    func presentPlaylistEditor(_ request: PlaylistEditorRequest) {
        guard isLibraryOpen(request.source) else { requestLogin(request.source); return }
        let title = if case .edit = request.purpose { "编辑歌单" } else { "新建歌单" }
        playlistEditorWindow.show(title: title, model: self) {
            PlaylistEditorView(request: request)
        }
    }

    func closePlaylistEditor() {
        playlistEditorWindow.close()
    }

    /// Makes the playlist; it joins the sidebar after the liked list and takes `tracks`, or opens
    /// when there are none. A failure to add the songs leaves the new playlist and says so.
    func createPlaylist(in id: SourceID, _ draft: PlaylistDraft, adding tracks: [Track]) async throws {
        let source = try require(id, as: (any PlaylistEditingSource).self, "新建歌单")
        var playlist = try await source.createPlaylist(draft)
        if playlist.isPrivate == nil { playlist.isPrivate = draft.isPrivate }
        let liked = likedPlaylistIDs[id]
        withAnimation(Motion.listEdit) {
            updatePlaylists(of: id) { playlists in
                let after = playlists.firstIndex { $0.id == liked }.map { $0 + 1 } ?? 0
                playlists.insert(playlist, at: after)
            }
        }
        let ids = tracks.filter { $0.id.source == id }.map(\.id.id)
        guard !ids.isEmpty else {
            navigate(.collection(playlist))
            showToast("已新建歌单「\(playlist.name)」")
            return
        }
        do {
            let added = try await source.addTracks(ids, toPlaylist: playlist.id)
            tookSongs(playlist, added: added)
            showToast(added == 1 ? "已新建「\(playlist.name)」并加入这首歌" : "已新建「\(playlist.name)」并加入 \(added) 首歌")
        } catch {
            showToast("已新建「\(playlist.name)」，但歌曲没有加进去：\(ErrorText.describe(error))")
        }
    }

    func editPlaylist(_ playlist: Playlist, _ changes: PlaylistChanges) async throws {
        guard !changes.isEmpty else { return }
        try await require(playlist.source, as: (any PlaylistEditingSource).self, "编辑歌单").editPlaylist(playlist.id, changes: changes)
        var now = playlist
        if let name = changes.name { now.name = name }
        if let description = changes.description { now.description = description.isEmpty ? nil : description }
        if let isPrivate = changes.isPrivate { now.isPrivate = isPrivate }
        updatePlaylists(of: playlist.source) { playlists in
            guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
            playlists[index].name = now.name
            playlists[index].description = now.description
            playlists[index].isPrivate = now.isPrivate
        }
        post(now, .edited)
    }

    func deletePlaylist(_ playlist: Playlist) async throws {
        try await require(playlist.source, as: (any PlaylistEditingSource).self, "删除歌单").deletePlaylist(playlist.id)
        withAnimation(Motion.listEdit) {
            updatePlaylists(of: playlist.source) { $0.removeAll { $0.id == playlist.id } }
        }
        if case .collection(let shown) = route, shown.id == playlist.id, shown.source == playlist.source {
            if canGoBack { goBack() } else { navigate(.home) }
        }
        post(playlist, .deleted)
        showToast("已删除歌单「\(playlist.name)」")
    }

    func removeSongs(_ refs: [TrackRef], from playlist: Playlist) async throws {
        let ids = refs.filter { $0.source == playlist.source }.map(\.id)
        guard !ids.isEmpty else { return }
        try await require(playlist.source, as: (any PlaylistEditingSource).self, "从歌单删除歌曲").removeTracks(ids, fromPlaylist: playlist.id)
        var now = playlist
        updatePlaylists(of: playlist.source) { playlists in
            guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
            playlists[index].trackCount = max(playlists[index].trackCount - ids.count, 0)
            now = playlists[index]
        }
        post(now, .removed(Set(refs)))
    }

    func reorder(_ playlist: Playlist, to ids: [String]) async throws {
        try await require(playlist.source, as: (any PlaylistEditingSource).self, "调整歌单顺序").reorderPlaylist(playlist.id, trackIDs: ids)
    }
}
