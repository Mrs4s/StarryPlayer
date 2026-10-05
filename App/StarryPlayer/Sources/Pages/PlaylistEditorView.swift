import MusicSources
import StarryCore
import SwiftUI

struct PlaylistEditorView: View {
    let request: PlaylistEditorRequest
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var summary = ""
    @State private var isPrivate = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var dealt = false
    @FocusState private var nameFocused: Bool

    private var nameLimit: Int { editing.nameLimit ?? 100 }

    private var editing: PlaylistEditing { model.playlistEditing(of: request.source) ?? PlaylistEditing() }

    private var playlist: Playlist? {
        if case .edit(let playlist) = request.purpose { return playlist }
        return nil
    }

    private var adding: [Track] {
        if case .create(let tracks) = request.purpose { return tracks }
        return []
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 16) {
            preview
                .padding(.top, 4)
            Text(playlist == nil ? (adding.isEmpty ? "新建歌单" : "新建歌单并加入") : "编辑歌单")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.onSurface)
            fields
            if showsPrivacy { privacyRow }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Color(hex: "#F0625D"))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            buttons
                .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: 380)
        .background(theme.surfaceAlt.ignoresSafeArea())
        .modifier(WindowCancelShortcut { model.closePlaylistEditor() })
        .animation(Motion.popover, value: error)
        .confirmationDialog("删除歌单「\(playlist?.name ?? "")」？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { Task { await delete() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后不能恢复，歌单里的歌曲本身不受影响。")
        }
        .onAppear {
            if let playlist {
                name = playlist.name
                summary = playlist.description ?? ""
                isPrivate = playlist.isPrivate ?? false
            } else {
                isPrivate = editing.privateByDefault
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72).delay(0.08)) { dealt = true }
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                nameFocused = true
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let playlist {
            ArtworkView(artwork: playlist.artwork, radius: 14)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        } else if adding.isEmpty {
            NameTile(name: trimmedName)
                .frame(width: 96, height: 96)
                .scaleEffect(dealt ? 1 : 0.86)
                .opacity(dealt ? 1 : 0)
        } else {
            fannedCovers
        }
    }

    private var fannedCovers: some View {
        let shown = Array(adding.prefix(3))
        let middle = Double(shown.count - 1) / 2
        return ZStack {
            ForEach(Array(shown.enumerated().reversed()), id: \.offset) { index, track in
                let offset = Double(index) - middle
                ArtworkView(artwork: track.album?.artwork, radius: 12)
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                    .rotationEffect(.degrees(dealt ? offset * 9 : 0))
                    .offset(x: dealt ? offset * 26 : 0, y: dealt ? abs(offset) * 5 : 0)
            }
        }
        .frame(width: 150, height: 100)
        .overlay(alignment: .bottomTrailing) {
            if adding.count > 1 {
                Text("\(adding.count) 首")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.onPrimary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(theme.primary, in: Capsule())
                    .scaleEffect(dealt ? 1 : 0.5)
                    .opacity(dealt ? 1 : 0)
            }
        }
    }

    private var fields: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("歌单名称", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit { Task { await save() } }
                    .onChange(of: name) { _, value in
                        if value.count > nameLimit { name = String(value.prefix(nameLimit)) }
                    }
                if let limit = editing.nameLimit, nameFocused || name.count > limit - 5 {
                    Text("\(name.count)/\(limit)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            if editing.keepsDescription {
                Rectangle().fill(theme.outlineVariant).frame(height: 1)
                ZStack(alignment: .topLeading) {
                    if summary.isEmpty {
                        Text("简介（可不填）").foregroundStyle(theme.onSurfaceVariant.opacity(0.6))
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $summary)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 8)
                }
                .frame(height: 84)
            }
        }
        .font(.system(size: 13))
        .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.menu))
        .animation(Motion.hover, value: nameFocused)
    }

    private var showsPrivacy: Bool {
        editing.keepsPrivacy && (playlist == nil || playlist?.isPrivate != nil)
    }

    /// A public playlist on a platform that cannot hide it again stays public.
    private var privacyLocked: Bool {
        editing.publicIsFinal && playlist?.isPrivate == false
    }

    private var privacyRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("隐私歌单").font(.system(size: 13)).foregroundStyle(theme.onSurface)
                Text(privacyLocked ? "公开的歌单在\(model.displayName(of: request.source))不能再设为隐私" : "只有你自己能看到")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
            SettingsSwitch(isOn: $isPrivate)
                .disabled(privacyLocked)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.menu))
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if let playlist, model.canDelete(playlist) {
                Button("删除歌单") { confirmingDelete = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#F0625D"))
                    .disabled(busy)
            }
            Spacer(minLength: 0)
            PillButton(title: "取消", variant: .ghost, height: 32) { model.closePlaylistEditor() }
            PillButton(title: saveTitle, variant: .filled, height: 32) { Task { await save() } }
                .disabled(busy || trimmedName.isEmpty)
        }
    }

    private var saveTitle: String {
        if busy { return playlist == nil ? "正在创建…" : "正在保存…" }
        if playlist != nil { return "保存" }
        return adding.isEmpty ? "创建" : "创建并加入"
    }

    private func save() async {
        let name = trimmedName
        guard !busy, !name.isEmpty else { return }
        busy = true
        error = nil
        do {
            if let playlist {
                var changes = PlaylistChanges()
                if name != playlist.name { changes.name = name }
                if editing.keepsDescription, summary != (playlist.description ?? "") { changes.description = summary }
                if showsPrivacy, !privacyLocked, isPrivate != (playlist.isPrivate ?? false) { changes.isPrivate = isPrivate }
                try await model.editPlaylist(playlist, changes)
            } else {
                let draft = PlaylistDraft(name: name, description: editing.keepsDescription && !summary.isEmpty ? summary : nil, isPrivate: editing.keepsPrivacy ? isPrivate : nil)
                try await model.createPlaylist(in: request.source, draft, adding: adding)
            }
            model.closePlaylistEditor()
        } catch {
            self.error = ErrorText.describe(error)
            busy = false
        }
    }

    private func delete() async {
        guard let playlist, !busy else { return }
        busy = true
        error = nil
        do {
            try await model.deletePlaylist(playlist)
            model.closePlaylistEditor()
        } catch {
            self.error = ErrorText.describe(error)
            busy = false
        }
    }
}

private struct NameTile: View {
    let name: String

    private var hue: Double {
        guard !name.isEmpty else { return 0.98 }
        let sum = name.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value }
        return Double(sum % 360) / 360
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.95), Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.78)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Group {
                    if let first = name.first {
                        Text(String(first)).font(.system(size: 40, weight: .bold, design: .rounded))
                    } else {
                        Image(systemName: "music.note.list").font(.system(size: 34, weight: .semibold))
                    }
                }
                .foregroundStyle(.white.opacity(0.92))
                .contentTransition(.interpolate)
            }
            .shadow(color: Color(hue: hue, saturation: 0.6, brightness: 0.6).opacity(0.35), radius: 12, y: 5)
            .animation(.smooth(duration: 0.45), value: hue)
            .animation(.snappy(duration: 0.25), value: name.first)
    }
}
