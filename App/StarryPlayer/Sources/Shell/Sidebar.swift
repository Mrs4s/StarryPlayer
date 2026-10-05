import MusicSources
import StarryCore
import SwiftUI

private struct SidebarEntry: Identifiable {
    var key: String
    var title: String
    var icon: String
    var route: Route
    var origin: PlaybackOrigin? = nil
    /// The page shows the browsing source's content (daily recommendations, the liked list, all
    /// media), not the app's own (home, recently played).
    var ofSource = false
    var id: String { key }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Namespace private var selection
    @State private var dropTarget: String?
    @State private var deleting: Playlist?

    private var discover: [SidebarEntry] {
        var entries = [SidebarEntry(key: "home", title: "首页", icon: "house", route: .home)]
        if model.hasDailyRecommendations {
            entries.append(SidebarEntry(key: "daily", title: "每日推荐", icon: "calendar", route: .daily, origin: .dailyRecommendation, ofSource: true))
        }
        return entries
    }

    private var mine: [SidebarEntry] {
        var entries: [SidebarEntry] = []
        if model.hasLibrary {
            entries.append(SidebarEntry(key: "liked", title: "我喜欢的音乐", icon: "heart", route: .liked, origin: .liked, ofSource: true))
        }
        entries.append(SidebarEntry(key: "history", title: "最近播放", icon: "clock", route: .history, origin: .history))
        if model.hasAllMedia {
            entries.append(SidebarEntry(key: "allMedia", title: "所有媒体", icon: "square.stack", route: .allMedia, origin: .allMedia, ofSource: true))
        }
        for section in model.librarySections {
            switch section {
            case .albums: entries.append(SidebarEntry(key: "libraryAlbums", title: "专辑", icon: "opticaldisc", route: .libraryAlbums(genre: nil)))
            case .artists: entries.append(SidebarEntry(key: "libraryArtists", title: "歌手", icon: "music.mic", route: .libraryArtists))
            case .genres: entries.append(SidebarEntry(key: "libraryGenres", title: "流派", icon: "guitars", route: .libraryGenres))
            case .folders: entries.append(SidebarEntry(key: "libraryFolder", title: "文件夹", icon: "folder", route: .libraryFolder(nil), origin: .local, ofSource: true))
            }
        }
        return entries
    }

    private var collapsed: Bool { model.sidebarCollapsed && model.sidebarMode == .docked }

    /// The row that carries the selection pill; nil on pages the sidebar does not list.
    private var selectedKey: String? {
        switch model.route {
        case .home: "home"
        case .daily: "daily"
        case .liked: "liked"
        case .history: "history"
        case .allMedia: "allMedia"
        case .libraryAlbums(nil): "libraryAlbums"
        case .libraryArtists: "libraryArtists"
        case .libraryGenres: "libraryGenres"
        case .libraryFolder(nil): "libraryFolder"
        case .collection(let playlist): Self.playlistKey(playlist)
        default: nil
        }
    }

    private static func playlistKey(_ playlist: Playlist) -> String { "playlist.\(playlist.source.key).\(playlist.id)" }

    var body: some View {
        VStack(spacing: 0) {
            titleBarStrip
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(discover) { entryRow($0) }
                    let mineEntries = mine
                    SidebarGroup(id: "mine", title: "我的音乐", sidebarCollapsed: collapsed) {
                        ForEach(Array(mineEntries.enumerated()), id: \.element.id) { index, entry in
                            entryRow(entry).transition(.sidebarRow(index))
                        }
                    }
                    .zIndex(mineEntries.contains { $0.key == selectedKey } ? 1 : 0)
                    // The account's own part goes as one when the sidebar browses as another
                    // account: it fades while the new one rises into the same place (a ZStack, so
                    // the two do not stack up while they pass).
                    ZStack(alignment: .top) {
                        accountSection
                            .id(accountKey)
                            .transition(.accountSwap)
                    }
                    .zIndex((model.userPlaylists + model.subscribedPlaylists).contains { selectedKey == Self.playlistKey($0) } ? 1 : 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .animation(Motion.selection, value: selectedKey)
        .confirmationDialog("删除歌单「\(deleting?.name ?? "")」？", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }, presenting: deleting) { playlist in
            Button("删除", role: .destructive) {
                Task {
                    do {
                        try await model.deletePlaylist(playlist)
                    } catch {
                        model.showToast(ErrorText.describe(error))
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("删除后不能恢复，歌单里的歌曲本身不受影响。")
        }
    }

    private var accountKey: String { "\(model.browsingSourceID.key)|\(model.signedInUser ?? "")" }

    @ViewBuilder
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.isLoggedIn {
                let canCreate = model.playlistEditing(of: model.browsingSourceID)?.canCreate == true
                playlistGroup(id: "created", title: "创建的歌单", playlists: model.userPlaylists, onAdd: canCreate ? {
                    model.presentPlaylistEditor(PlaylistEditorRequest(source: model.browsingSourceID, purpose: .create(adding: [])))
                } : nil)
                playlistGroup(id: "subscribed", title: "收藏的歌单", playlists: model.subscribedPlaylists)
            } else if model.canLogIn(model.browsingSourceID) {
                loginPrompt
            }
        }
    }

    /// The selected row (and the group holding it) is drawn above its siblings: its pill, the
    /// one that slides, then passes over the rows between whichever way it goes. Otherwise it
    /// would slide over them going down but under their labels going up, like a shadow.
    private func entryRow(_ entry: SidebarEntry) -> some View {
        SidebarItem(title: entry.title, glyph: .symbol(entry.icon), active: selectedKey == entry.key, collapsed: collapsed, playing: entry.origin.flatMap { model.player.playState(from: $0, of: entry.ofSource ? model.browsingSourceID : nil) }, selection: selection) {
            model.navigate(entry.route)
        }
        .zIndex(selectedKey == entry.key ? 1 : 0)
    }

    /// Stays in place while the account's playlists load, so the rows, not the whole group,
    /// arrive — each with its own staggered transition. The title shows once there are rows, or
    /// at once when it has a + (new playlist).
    private func playlistGroup(id: String, title: String, playlists: [Playlist], onAdd: (() -> Void)? = nil) -> some View {
        SidebarGroup(id: id, title: title, sidebarCollapsed: collapsed, showsHeader: !playlists.isEmpty || onAdd != nil, onAdd: onAdd) {
            ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                let key = Self.playlistKey(playlist)
                let active = selectedKey == key
                let takesSongs = model.playlistsToAdd(of: playlist.source).contains { $0.id == playlist.id }
                SidebarItem(title: playlist.name, glyph: .artwork(playlist.artwork), active: active, collapsed: collapsed, playing: model.player.playState(from: .playlist, of: playlist.source, id: playlist.id), selection: selection,
                            receiving: dropTarget == key, pulse: pulse(of: playlist)) {
                    model.navigate(.collection(playlist))
                }
                .onDrop(of: [.starryTracks], delegate: PlaylistDrop(playlist: playlist, key: key, enabled: takesSongs, model: model, target: $dropTarget))
                .contextMenu { playlistMenu(playlist) }
                .transition(.sidebarRow(index))
                .zIndex(active ? 1 : 0)
            }
        }
        .zIndex(playlists.contains { selectedKey == Self.playlistKey($0) } ? 1 : 0)
    }

    private func pulse(of playlist: Playlist) -> Int {
        guard let pulse = model.playlistPulse, pulse.source == playlist.source, pulse.id == playlist.id else { return 0 }
        return pulse.serial
    }

    @ViewBuilder
    private func playlistMenu(_ playlist: Playlist) -> some View {
        if model.canEdit(playlist) {
            Button("编辑歌单…") { model.presentPlaylistEditor(PlaylistEditorRequest(source: playlist.source, purpose: .edit(playlist))) }
        }
        if model.canDelete(playlist) {
            Button("删除歌单…", role: .destructive) { deleting = playlist }
        }
    }

    /// The traffic lights' strip, level with the header bar; it drags the window. The floating
    /// panel starts `floatingSidebarInset` down, so its strip is that much shorter and the rows
    /// start at the same height; it also holds the button that hides the panel (or, out over
    /// the pages, pins it), level with the traffic lights, which move in beside it.
    @ViewBuilder
    private var titleBarStrip: some View {
        let mode = model.sidebarMode
        if mode == .docked {
            Color.clear
                .frame(height: Metrics.headerHeight)
                .contentShape(Rectangle())
                .modifier(WindowDrag())
        } else {
            let inset = Metrics.floatingSidebarInset
            let size: CGFloat = 28
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                IconButton(systemName: "sidebar.left", size: size, iconSize: 14, help: mode == .floating ? "隐藏侧栏（⌘S），指针移到窗口左缘时滑出" : "固定侧栏（⌘S）") {
                    model.toggleSidebar()
                }
                .padding(.top, WindowButtonsView.floatingCenterY - inset - size / 2)
                .padding(.trailing, 10)
            }
            .frame(height: Metrics.headerHeight - inset, alignment: .top)
            .contentShape(Rectangle())
            .modifier(WindowDrag())
        }
    }

    @ViewBuilder
    private var loginPrompt: some View {
        if collapsed {
            SidebarItem(title: "登录", glyph: .symbol("person.crop.circle"), active: false, collapsed: true, playing: nil, selection: selection) {
                model.requestLogin()
            }
            .padding(.top, 16)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("登录\(model.currentSourceName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                Text(model.loginBenefits(of: model.browsingSourceID))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.requestLogin() } label: {
                    Text("登录")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.onPrimary)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                }
                .buttonStyle(VariantButtonStyle(variant: .filled, isPill: true))
                .padding(.top, 8)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.onSurface.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 20)
            .transition(.opacity)
        }
    }
}

/// A sidebar row: 34 pt, a 22 pt glyph (symbol or cover) and a 13 pt label. The label has a
/// fixed width and the row clips it, so collapsing narrows the row over a label that stays
/// put instead of re-truncating it every frame; the glyph never moves.
private struct SidebarItem: View {
    enum Glyph {
        case symbol(String)
        case artwork(Artwork?)
    }

    var title: String
    var glyph: Glyph
    var active: Bool
    var collapsed: Bool
    /// nil when this row is not what is playing; otherwise whether it plays or is paused.
    var playing: Bool?
    var selection: Namespace.ID
    var receiving = false
    var pulse = 0
    var action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var clicks = 0

    static let glyphSize: CGFloat = 22
    static let inset: CGFloat = (Metrics.sidebarCollapsedWidth - 24 - glyphSize) / 2
    static let rowWidth: CGFloat = Metrics.sidebarWidth - 24
    static let labelWidth: CGFloat = rowWidth - inset - glyphSize - 10 - 10

    var body: some View {
        Button {
            clicks += 1
            action()
        } label: {
            HStack(spacing: 10) {
                glyphView
                    .frame(width: Self.glyphSize, height: Self.glyphSize)
                    .keyframeAnimator(initialValue: 1.0, trigger: clicks) { content, scale in
                        content.scaleEffect(reduceMotion ? 1 : scale)
                    } keyframes: { _ in
                        KeyframeTrack(\.self) {
                            CubicKeyframe(0.8, duration: 0.08)
                            SpringKeyframe(1, duration: 0.45, spring: .bouncy)
                        }
                    }
                    .scaleEffect(receiving && !reduceMotion ? 1.18 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: receiving)
                    .modifier(TakeBeat(trigger: pulse, color: theme.accent, enabled: !reduceMotion))
                label
                    .frame(width: Self.labelWidth, alignment: .leading)
                    .opacity(collapsed ? 0 : 1)
            }
            .padding(.leading, Self.inset)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: Metrics.sidebarRowHeight, maxHeight: Metrics.sidebarRowHeight, alignment: .leading)
            .clipped()
            .background { background }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(SidebarPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(collapsed ? title : "")
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
                .symbolVariant(active ? .fill : .none)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(active ? theme.accent : theme.onSurface.opacity(hovering ? 0.8 : 0.6))
                .contentTransition(.symbolEffect(.replace))
        case .artwork(let artwork):
            ArtworkView(artwork: artwork, radius: 5, pixelSize: 64)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(theme.onSurface.opacity(0.08), lineWidth: 0.5))
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(theme.onSurface.opacity(active ? 1 : 0.82))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let playing {
                SidebarPlayingBars(playing: playing)
                    .frame(width: 12, height: 11)
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if receiving {
            shape.fill(theme.accent.opacity(theme.isDark ? 0.24 : 0.18))
                .overlay(shape.strokeBorder(theme.accent.opacity(0.55), lineWidth: 1.5))
        } else if active {
            shape.fill(theme.accent.opacity(theme.isDark ? 0.16 : 0.12))
                .matchedGeometryEffect(id: "sidebar.selection", in: selection)
        } else if hovering {
            shape.fill(theme.onSurface.opacity(0.05))
        }
    }
}

/// The playing row's bars: still while Now Playing covers the shell or the hidden sidebar is
/// out of sight (`isPageActive`). Only this leaf reads those, not every row.
private struct SidebarPlayingBars: View {
    var playing: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.isPageActive) private var visible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PlayingBars(color: theme.accent, animating: playing && visible && !model.player.showNowPlaying && !reduceMotion)
    }
}

private struct TakeBeat: ViewModifier {
    var trigger: Int
    var color: Color
    var enabled: Bool

    private struct Frame {
        var scale = 1.0
        var ring = 1.0
        var ringOpacity = 0.0
    }

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: Frame(), trigger: trigger) { content, frame in
            content
                .scaleEffect(enabled ? frame.scale : 1)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(color, lineWidth: 1.5)
                        .scaleEffect(frame.ring)
                        .opacity(enabled ? frame.ringOpacity : 0)
                }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(0.82, duration: 0.1)
                SpringKeyframe(1.22, duration: 0.18, spring: .snappy)
                SpringKeyframe(1, duration: 0.5, spring: .bouncy)
            }
            KeyframeTrack(\.ring) {
                LinearKeyframe(1, duration: 0.1)
                CubicKeyframe(2.1, duration: 0.6)
            }
            KeyframeTrack(\.ringOpacity) {
                LinearKeyframe(0, duration: 0.1)
                LinearKeyframe(0.9, duration: 0.05)
                CubicKeyframe(0, duration: 0.55)
            }
        }
    }
}

private struct PlaylistDrop: DropDelegate {
    let playlist: Playlist
    let key: String
    let enabled: Bool
    let model: AppModel
    @Binding var target: String?

    private func tracks(_ info: DropInfo) -> [Track] {
        guard enabled else { return [] }
        return model.draggedTracks(in: info).filter { $0.id.source == playlist.source }
    }

    func validateDrop(info: DropInfo) -> Bool { !tracks(info).isEmpty }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        target = key
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info) ? DropProposal(operation: .copy) : DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) {
        if target == key { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let tracks = tracks(info)
        target = nil
        guard !tracks.isEmpty else { return false }
        model.add(tracks, to: playlist)
        return true
    }
}

private struct SidebarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A titled run of rows that folds from its title (remembered per group). The chevron shows on
/// hover, and stays while folded. Collapsed to icons, the title becomes a short rule of the
/// same height, so the rows do not shift, and folding is off.
private struct SidebarGroup<Content: View>: View {
    var title: String
    var sidebarCollapsed: Bool
    var showsHeader: Bool
    var onAdd: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @AppStorage private var folded: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    init(id: String, title: String, sidebarCollapsed: Bool, showsHeader: Bool = true, onAdd: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.sidebarCollapsed = sidebarCollapsed
        self.showsHeader = showsHeader
        self.onAdd = onAdd
        self.content = content
        _folded = AppStorage(wrappedValue: false, "starry.sidebar.folded.\(id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsHeader {
                header.transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
            if !folded || sidebarCollapsed {
                content()
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(Motion.fold) { folded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .opacity(hovering || folded ? 1 : 0)
                Spacer(minLength: 0)
            }
            .padding(.leading, SidebarItem.inset)
            .opacity(sidebarCollapsed ? 0 : 1)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .clipped()
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(theme.outlineVariant)
                    .frame(width: 16, height: 1.5)
                    .padding(.leading, (Metrics.sidebarCollapsedWidth - 24 - 16) / 2)
                    .opacity(sidebarCollapsed ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sidebarCollapsed)
        .overlay(alignment: .trailing) {
            if let onAdd, !sidebarCollapsed {
                AddButton(action: onAdd, emphasized: hovering)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .padding(.top, 14)
    }
}

private struct AddButton: View {
    var action: () -> Void
    var emphasized: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.onSurfaceVariant.opacity(hovering ? 1 : (emphasized ? 0.85 : 0.5)))
                .frame(width: 22, height: 22)
                .background(Circle().fill(theme.onSurface.opacity(hovering ? 0.08 : 0)))
                .symbolEffect(.bounce, value: taps)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help("新建歌单")
        .padding(.trailing, 4)
    }
}

private extension AnyTransition {
    static var accountSwap: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .offset(y: 10)).animation(Motion.fold.delay(0.06)),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.12))
        )
    }

    /// A sidebar row arriving drops in from just above, a beat after the one before it; a row
    /// leaving just fades. The animations ride on the transition, so rows that arrive without
    /// an animated transaction (playlists loaded after login) still come in this way.
    static func sidebarRow(_ index: Int) -> AnyTransition {
        .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .offset(y: -6)).animation(Motion.fold.delay(Double(min(index, 10)) * 0.025)),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.12))
        )
    }
}
