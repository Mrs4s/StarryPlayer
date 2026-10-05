import MusicSources
import StarryCore
import SwiftUI

/// The add to playlist submenu in a song's menus: new playlist… and the account's own playlists
/// in the song's source (not the liked list, which the heart fills). Signed out, it asks to sign in. Nothing shows when
/// the source keeps no playlists of its own.
struct AddToPlaylistMenu: View {
    let tracks: [Track]
    var systemImage: String? = nil
    var excluding: String? = nil
    @Environment(AppModel.self) private var model

    private var source: SourceID? { tracks.first?.id.source }

    var body: some View {
        if let source, let editing = model.playlistEditing(of: source), editing.canAdd {
            Menu {
                if !model.isLibraryOpen(source) {
                    Button("登录\(model.displayName(of: source))后加入…") { model.requestLogin(source) }
                } else {
                    if editing.canCreate {
                        Button("新建歌单…") { model.presentPlaylistEditor(PlaylistEditorRequest(source: source, purpose: .create(adding: tracks))) }
                    }
                    let playlists = model.playlistsToAdd(of: source).filter { $0.id != excluding }
                    if !playlists.isEmpty {
                        Divider()
                        ForEach(playlists) { playlist in
                            Button(playlist.name) { model.add(tracks, to: playlist) }
                        }
                    }
                }
            } label: {
                if let systemImage { Label("加入歌单", systemImage: systemImage) } else { Text("加入歌单") }
            }
        }
    }
}
