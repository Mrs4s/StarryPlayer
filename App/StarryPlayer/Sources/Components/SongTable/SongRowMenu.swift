import AppKit
import StarryCore

@MainActor
enum SongRowMenu {
    static func make(for track: Track, model: AppModel, play: @escaping @MainActor () -> Void, removeFromPlaylist: (@MainActor () -> Void)?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("立即播放", play))
        menu.addItem(item("下一首播放") { model.player.playNext(track) })
        menu.addItem(item("添加到队列") { model.player.addToQueue(track) })
        if let submenu = addToPlaylist(tracks: [track], model: model) {
            let item = NSMenuItem(title: "加入歌单", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if model.canLike(track) {
            menu.addItem(item(model.player.isLiked(track) ? "取消喜欢" : "喜欢") { model.toggleLike(track) })
        }
        if track.album?.isLinkable == true {
            menu.addItem(item("查看专辑") { model.showAlbum(of: track) })
        }
        for artist in track.artists.filter(\.isLinkable) {
            menu.addItem(item("查看歌手：\(artist.name)") { model.showArtist(artist, of: track) })
        }
        if let path = track.localPath {
            menu.addItem(item("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) })
        }
        if let removeFromPlaylist {
            menu.addItem(.separator())
            menu.addItem(item("从歌单中删除", removeFromPlaylist))
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    static func addToPlaylist(tracks: [Track], model: AppModel, excluding: String? = nil) -> NSMenu? {
        guard let source = tracks.first?.id.source, let editing = model.playlistEditing(of: source), editing.canAdd else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !model.isLibraryOpen(source) {
            menu.addItem(item("登录\(model.displayName(of: source))后加入…") { model.requestLogin(source) })
            return menu
        }
        if editing.canCreate {
            menu.addItem(item("新建歌单…") { model.presentPlaylistEditor(PlaylistEditorRequest(source: source, purpose: .create(adding: tracks))) })
        }
        let playlists = model.playlistsToAdd(of: source).filter { $0.id != excluding }
        if !playlists.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for playlist in playlists {
                menu.addItem(item(playlist.name) { model.add(tracks, to: playlist) })
            }
        }
        return menu
    }

    private static func item(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, action: action)
    }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let perform: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        perform = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() {
        perform()
    }
}
