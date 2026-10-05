import SwiftUI

struct LyricsSettingsPanel: View {
    var openSettings: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var revealing = false

    var body: some View {
        let advanced = model.showsAdvancedSettings
        let groups = SettingsCatalog(model: model).popoverGroups.compactMap { $0.visible(advanced: advanced) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("歌词与背景")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                    .padding(.leading, 4)
                ForEach(groups) { group in
                    SettingsGroupView(group: group)
                        .transition(.settingsEntry)
                }
                HStack {
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding { advanced } set: { setAdvanced($0) })
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                        Text("高级设置").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.onSurface)
                    }
                    Spacer()
                    Button(action: openSettings) {
                        HStack(spacing: 3) {
                            Text("在设置中打开")
                            Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .frame(width: 400, height: 580)
        .background(theme.surface)
        .tint(theme.accent)
        .environment(\.settingsCompact, true)
        .environment(\.settingsRevealing, revealing)
    }

    private func setAdvanced(_ on: Bool) {
        revealing = on
        withAnimation(Motion.fold) { model.showsAdvancedSettings = on }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            revealing = false
        }
    }
}
