import LocalLibrary
import MusicSources
import StarryCore
import SwiftUI

struct LocalLibraryWelcome: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let status = model.localStatus
        let scanning = !status.folders.isEmpty
        HStack(alignment: .center, spacing: 20) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.accent.opacity(0.12))
                .frame(width: 76, height: 76)
                .overlay {
                    Image(systemName: scanning ? "waveform.badge.magnifyingglass" : "folder.badge.plus")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(theme.accent)
                        .contentTransition(.symbolEffect(.replace))
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(scanning ? "正在整理你的音乐" : "把你的音乐带进来")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.onSurface)
                Text(scanning ? LocalLibrarySummary.statusLine(status) : "添加存放音乐的文件夹，或者直接把文件夹拖进窗口。支持 MP3、AAC、ALAC、FLAC、WAV、AIFF、Ogg 与 Opus。")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    PillButton(title: "添加文件夹…", systemName: "plus", variant: scanning ? .tertiary : .filled) { model.chooseLocalFolders() }
                    PillButton(title: "本地音乐设置", systemName: "gearshape", variant: .tertiary) { model.openSettings(page: .source(.local)) }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.035), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .animation(Motion.reveal, value: status)
    }
}
