import StarryCore
import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, playback, nowPlaying, lyrics, account, storage, plugins, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .appearance: "外观"
        case .playback: "播放"
        case .nowPlaying: "播放页"
        case .lyrics: "歌词"
        case .account: "账号"
        case .storage: "存储"
        case .plugins: "插件"
        case .about: "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .playback: "play.circle"
        case .nowPlaying: "text.below.photo"
        case .lyrics: "text.quote"
        case .account: "person.crop.circle"
        case .storage: "internaldrive"
        case .plugins: "puzzlepiece.extension"
        case .about: "info.circle"
        }
    }

    var summary: String {
        switch self {
        case .general: "启动方式与键盘快捷键"
        case .appearance: "颜色、主题与窗口布局"
        case .playback: "音质、输出设备、切歌与唱歌"
        case .nowPlaying: "歌词的样子与背景效果"
        case .lyrics: "歌词来源与菜单栏歌词"
        case .account: "登录的账号与听歌记录"
        case .storage: "缓存与本地数据"
        case .plugins: "第三方音源与歌词源"
        case .about: "版本信息与更新"
        }
    }
}

enum SettingsPage: Hashable, Identifiable {
    case app(SettingsCategory)
    case source(SourceID)

    var id: String {
        switch self {
        case .app(let category): category.rawValue
        case .source(let id): "source.\(id.key)"
        }
    }
}

struct SettingsPageInfo {
    var title: String
    var icon: String
    var summary: String
}

struct SettingsEntry: Identifiable {
    enum Layout {
        case row
        case block
        case custom
    }

    let id: String
    var title: String
    var detail: String?
    var keywords: String
    var advanced: Bool
    var layout: Layout
    var content: AnyView

    init<Content: View>(_ id: String, _ title: String, detail: String? = nil, keywords: String = "", advanced: Bool = false, layout: Layout = .row, @ViewBuilder content: () -> Content) {
        self.id = id
        self.title = title
        self.detail = detail
        self.keywords = keywords
        self.advanced = advanced
        self.layout = layout
        self.content = AnyView(content())
    }
}

struct SettingsGroup: Identifiable {
    let id: String
    var title: String?
    var footer: String?
    var advanced: Bool
    var entries: [SettingsEntry]

    init(_ id: String, title: String? = nil, footer: String? = nil, advanced: Bool = false, entries: [SettingsEntry]) {
        self.id = id
        self.title = title
        self.footer = footer
        self.advanced = advanced
        self.entries = entries
    }

    /// The group as shown with advanced settings on or off; nil when nothing of it shows.
    func visible(advanced showAdvanced: Bool) -> SettingsGroup? {
        guard showAdvanced || !advanced else { return nil }
        var group = self
        group.entries = entries.filter { showAdvanced || !$0.advanced }
        return group.entries.isEmpty ? nil : group
    }
}

extension EnvironmentValues {
    @Entry var settingsQuery = ""
    @Entry var settingsRevealing = false
    @Entry var settingsCompact = false
}

struct SettingsGroupView: View {
    var group: SettingsGroup
    var tagsAdvanced = false
    var header: AnyView? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                header
            } else if let title = group.title {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.onSurfaceVariant)
                    if group.advanced { AdvancedTag() }
                }
                .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    SettingsEntryRow(entry: entry, isAdvanced: group.advanced || entry.advanced, tagged: tagsAdvanced && (group.advanced || entry.advanced))
                        .overlay(alignment: .top) {
                            if index > 0 {
                                Rectangle().fill(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.06)).frame(height: 1).padding(.leading, 16)
                            }
                        }
                        .transition(.settingsEntry)
                }
            }
            .background(theme.surfacePanel)
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.06), lineWidth: 1))
            if let footer = group.footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct SettingsEntryRow: View {
    var entry: SettingsEntry
    var isAdvanced: Bool
    var tagged: Bool
    @Environment(\.theme) private var theme
    @Environment(\.settingsQuery) private var query
    @Environment(\.settingsRevealing) private var revealing
    @Environment(\.settingsCompact) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    var body: some View {
        Group {
            switch entry.layout {
            case .row:
                HStack(spacing: 16) {
                    labels
                    Spacer(minLength: 12)
                    entry.content.fixedSize()
                }
            case .block:
                VStack(alignment: .leading, spacing: 12) {
                    labels
                    entry.content
                }
            case .custom:
                entry.content
            }
        }
        .padding(.horizontal, entry.layout == .custom ? 0 : (compact ? 12 : 16))
        .padding(.vertical, entry.layout == .custom ? 0 : (compact ? 8 : 12))
        .frame(maxWidth: .infinity, minHeight: entry.layout == .custom ? 0 : (compact ? 40 : 52), alignment: .leading)
        .background(theme.accent.opacity(lit ? (theme.isDark ? 0.16 : 0.1) : 0))
        .onAppear {
            // A row brought in by turning advanced settings on glows and fades, so the eye finds
            // it.
            guard revealing, isAdvanced, !reduceMotion else { return }
            lit = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(420))
                withAnimation(.easeOut(duration: 1.1)) { lit = false }
            }
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(SettingsHighlight.text(entry.title, query: query, accent: theme.accent))
                    .font(.system(size: compact ? 12.5 : 13.5, weight: .medium))
                    .foregroundStyle(theme.onSurface)
                if tagged { AdvancedTag() }
            }
            if !compact, let detail = entry.detail, !detail.isEmpty {
                Text(SettingsHighlight.text(detail, query: query, accent: theme.accent, size: 12))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
        }
    }
}

enum SettingsHighlight {
    static func text(_ string: String, query: String, accent: Color, size: CGFloat = 13.5) -> AttributedString {
        var text = AttributedString(string)
        let terms = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        for term in terms {
            var searchStart = text.startIndex
            while let range = text[searchStart...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].foregroundColor = accent
                text[range].font = .system(size: size, weight: .semibold)
                searchStart = range.upperBound
            }
        }
        return text
    }
}

struct AdvancedTag: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("高级")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(theme.accent.opacity(theme.isDark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

extension AnyTransition {
    static var settingsEntry: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity)
    }
}

struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }
}

struct SettingsMenu<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(Value, String)]
    var width: CGFloat? = nil
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].1).tag(options[index].0)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == selection }?.1 ?? "")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .frame(maxWidth: width.map { $0 - 42 }, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .foregroundStyle(theme.onSurface)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background(theme.onSurface.opacity(hovering ? 0.1 : 0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

struct SettingsSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double? = nil
    var width: CGFloat = 150
    var format: (Double) -> String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ProgressSlider(value: Binding { value } set: { newValue in
                let stepped = step.map { (newValue / $0).rounded() * $0 } ?? newValue
                let clamped = min(max(stepped, range.lowerBound), range.upperBound)
                if clamped != value { value = clamped }
            }, range: range, trackHeight: 4, thumbSize: 14, tint: theme.accent, alwaysShowThumb: true)
                .frame(width: width)
            Text(format(value))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.onSurfaceVariant)
                .contentTransition(.numericText(value: value))
                .frame(minWidth: 44, alignment: .trailing)
        }
    }
}

struct SettingsButton: View {
    enum Role { case normal, prominent, destructive }
    var title: String
    var systemName: String? = nil
    var role: Role = .normal
    var action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemName {
                    Image(systemName: systemName).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(VariantButtonStyle(variant: role == .prominent ? .filled : .tertiary, isPill: true))
        .fixedSize()
    }

    private var foreground: Color {
        switch role {
        case .normal: theme.onSurface
        case .prominent: theme.onPrimary
        case .destructive: Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A")
        }
    }
}

/// A text setting kept as a draft while typing and saved on Return or when the field loses
/// focus, so a half-typed address is never used. `secure` hides what is typed.
struct SettingsTextField: View {
    @Binding var text: String
    var placeholder: String
    var width: CGFloat = 220
    var secure = false
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var draft: String?
    @State private var hovering = false

    var body: some View {
        let binding = Binding { draft ?? text } set: { draft = $0 }
        Group {
            if secure {
                SecureField(placeholder, text: binding)
            } else {
                TextField(placeholder, text: binding)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12.5))
        .focused($focused)
        .onSubmit(commit)
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .padding(.horizontal, 12)
        .frame(width: width, height: 28)
        .background(theme.onSurface.opacity(focused ? 0.08 : (hovering ? 0.09 : 0.06)), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.onSurface.opacity(focused ? 0.16 : 0), lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: focused)
    }

    private func commit() {
        guard let draft else { return }
        self.draft = nil
        let value = draft.trimmingCharacters(in: .whitespaces)
        if value != text { text = value }
    }
}

struct VisualPicker<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var preview: (_ hovering: Bool) -> AnyView
    }

    @Binding var selection: Value
    var options: [Option]
    var previewSize = CGSize(width: 104, height: 66)
    @Namespace private var ring

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                VisualPickerOption(title: option.title, selected: selection == option.value, size: previewSize, ring: ring, preview: option.preview) {
                    guard selection != option.value else { return }
                    withAnimation(Motion.selection) { selection = option.value }
                }
            }
        }
    }
}

private struct VisualPickerOption: View {
    var title: String
    var selected: Bool
    var size: CGSize
    var ring: Namespace.ID
    var preview: (Bool) -> AnyView
    var action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview(hovering && isEnabled)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.onSurface.opacity(0.1), lineWidth: 1))
                    .padding(3.5)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(theme.accent, lineWidth: 2)
                                .matchedGeometryEffect(id: "ring", in: ring)
                        }
                    }
                    .scaleEffect(hovering && isEnabled && !selected ? 1.03 : 1)
                    .shadow(color: .black.opacity(hovering && isEnabled ? 0.12 : 0), radius: 8, y: 3)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.onSurface : theme.onSurfaceVariant)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.lift, value: hovering)
    }
}

struct SettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
