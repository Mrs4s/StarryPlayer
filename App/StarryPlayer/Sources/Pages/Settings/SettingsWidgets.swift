import AppKit
import Library
import MusicSources
import StarryCore
import SwiftUI

struct AppearancePreview: View {
    var appearance: AppSettings.Appearance
    @Environment(\.theme) private var theme

    var body: some View {
        switch appearance {
        case .light: MiniWindow(dark: false, accent: theme.accent)
        case .dark: MiniWindow(dark: true, accent: theme.accent)
        case .system:
            ZStack {
                MiniWindow(dark: false, accent: theme.accent)
                MiniWindow(dark: true, accent: theme.accent)
                    .mask(alignment: .trailing) { Rectangle().frame(width: 52) }
            }
        }
    }

    private struct MiniWindow: View {
        var dark: Bool
        var accent: Color

        var body: some View {
            let base = dark ? Theme.darkBase : Theme.lightBase
            let line = base.onSurface.opacity(dark ? 0.2 : 0.14)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(accent.opacity(0.8)).frame(width: 14, height: 3)
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(line).frame(width: 16, height: 3) }
                }
                .padding(.top, 12)
                .padding(.leading, 6)
                .frame(width: 26, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(base.onSurface.opacity(dark ? 0.05 : 0.035))
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(base.onSurface.opacity(dark ? 0.55 : 0.6)).frame(width: 30, height: 4)
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2.5).fill(accent.opacity(0.75))
                        RoundedRectangle(cornerRadius: 2.5).fill(line)
                        RoundedRectangle(cornerRadius: 2.5).fill(line)
                    }
                    .frame(height: 18)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3).fill(base.surfacePanel).frame(height: 9)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(base.onSurface.opacity(0.1), lineWidth: 0.5))
                }
                .padding(7)
            }
            .background(base.surface)
        }
    }
}

struct SidebarModePreview: View {
    var mode: AppSettings.SidebarMode
    var hovering: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let line = theme.onSurface.opacity(theme.isDark ? 0.2 : 0.14)
        ZStack(alignment: .leading) {
            theme.surface
            page(line: line)
                .padding(.leading, mode == .autoHide ? 8 : (mode == .floating ? 34 : 30))
            switch mode {
            case .docked:
                panel(line: line)
                    .frame(width: 28)
                    .frame(maxHeight: .infinity)
                    .background(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.035))
            case .floating:
                panel(line: line)
                    .frame(width: 26)
                    .frame(maxHeight: .infinity)
                    .background(theme.surfacePanel, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .padding(4)
            case .autoHide:
                panel(line: line)
                    .frame(width: 26)
                    .frame(maxHeight: .infinity)
                    .background(theme.surfacePanel, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                    .padding(4)
                    .offset(x: hovering ? 0 : -34)
                    .animation(hovering ? Motion.sidebarPeek : Motion.sidebarUnpeek, value: hovering)
                Capsule().fill(theme.accent.opacity(hovering ? 0 : 0.7)).frame(width: 2, height: 18).padding(.leading, 2)
                    .animation(Motion.hover, value: hovering)
            }
        }
    }

    private func page(line: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(theme.onSurface.opacity(0.5)).frame(width: 26, height: 4)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2.5).fill(index == 0 ? theme.accent.opacity(0.7) : line)
                }
            }
            .frame(height: 18)
            Spacer(minLength: 0)
        }
        .padding(7)
    }

    private func panel(line: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(theme.accent.opacity(0.25)).frame(height: 5)
            ForEach(0..<3, id: \.self) { _ in Capsule().fill(line).frame(width: 14, height: 3) }
        }
        .padding(.horizontal, 5)
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct PlayerBarPreview: View {
    var style: AppSettings.PlayerBarStyle
    var hovering: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let line = theme.onSurface.opacity(theme.isDark ? 0.2 : 0.14)
        ZStack(alignment: .bottom) {
            theme.surface
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2.5).fill(LinearGradient(colors: [theme.accent.opacity(0.9), theme.accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: 2.5).fill(line)
                    RoundedRectangle(cornerRadius: 2.5).fill(line)
                }
                .frame(height: 30)
                Spacer(minLength: 0)
            }
            .padding(7)
            bar.padding(.horizontal, 7).padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var bar: some View {
        let content = HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(theme.accent.opacity(0.8)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Capsule().fill(theme.onSurface.opacity(0.5)).frame(width: 22, height: 2.5)
                Capsule().fill(theme.onSurface.opacity(0.25)).frame(width: 14, height: 2)
            }
            Spacer(minLength: 0)
            Circle().fill(theme.onSurface.opacity(0.7)).frame(width: 6, height: 6)
        }
        .padding(.horizontal, 5)
        .frame(height: 14)
        switch style {
        case .classic:
            content
                .background(theme.surfacePanel, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Capsule().fill(theme.accent).frame(width: 30, height: 1.5).padding(.leading, 5).padding(.bottom, 0.5)
                }
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(theme.onSurface.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        case .glass:
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(theme.surfacePanel.opacity(0.35), in: Capsule())
                .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(LinearGradient(colors: [theme.accent.opacity(0), theme.accent, theme.accent.opacity(0)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 40, height: 1.5)
                        .shadow(color: theme.accent, radius: 2)
                        .offset(x: hovering ? 18 : -18, y: 0.5)
                        .animation(.easeInOut(duration: 0.9), value: hovering)
                }
                .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
        }
    }
}

struct ThemeColorSwatches: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Namespace private var ring

    static let defaultHex = "#FE7971"
    static let presets = ["#F5A623", "#34C38F", "#2BB5C8", "#3F7FF5", "#8A6CF0", "#EC5FA8"]

    private enum Swatch: Hashable {
        case cover, standard, preset(String), custom
    }

    private var selected: Swatch {
        let settings = model.settings.settings
        switch settings.themeColorMode {
        case .cover: return .cover
        case .default: return .standard
        case .custom:
            let hex = settings.customThemeColorHex.uppercased()
            return Self.presets.contains(hex) ? .preset(hex) : .custom
        }
    }

    var body: some View {
        let swatches: [Swatch] = [.cover, .standard] + Self.presets.map { .preset($0) } + [.custom]
        HStack(spacing: 7) {
            ForEach(swatches, id: \.self) { swatch in
                SwatchButton(help: help(swatch), selected: selected == swatch, ring: ring) {
                    fill(swatch)
                } action: {
                    pick(swatch)
                }
            }
        }
        .animation(Motion.selection, value: selected)
    }

    @ViewBuilder
    private func fill(_ swatch: Swatch) -> some View {
        switch swatch {
        case .cover:
            ZStack {
                Circle().fill(AngularGradient(colors: [Color(hex: "#FE7971"), Color(hex: "#F5A623"), Color(hex: "#34C38F"), Color(hex: "#3F7FF5"), Color(hex: "#8A6CF0"), Color(hex: "#FE7971")], center: .center))
                Circle().fill(model.player.accentColor ?? .clear).padding(4)
                Image(systemName: "music.note").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            }
        case .standard: Circle().fill(Color(hex: Self.defaultHex))
        case .preset(let hex): Circle().fill(Color(hex: hex))
        case .custom:
            ZStack {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                if selected == .custom {
                    Circle().fill(Color(hex: model.settings.settings.customThemeColorHex)).padding(4)
                } else {
                    Circle().fill(theme.surfacePanel).padding(4)
                    Image(systemName: "plus").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.onSurfaceVariant)
                }
            }
        }
    }

    private func help(_ swatch: Swatch) -> String {
        switch swatch {
        case .cover: "跟随封面"
        case .standard: "珊瑚色（默认）"
        case .preset: "预设颜色"
        case .custom: "自定义颜色…"
        }
    }

    private func pick(_ swatch: Swatch) {
        let store = model.settings
        switch swatch {
        case .cover: store.settings.themeColorMode = .cover
        case .standard: store.settings.themeColorMode = .default
        case .preset(let hex):
            store.settings.customThemeColorHex = hex
            store.settings.themeColorMode = .custom
        case .custom:
            let current = selected == .custom ? store.settings.customThemeColorHex : Self.defaultHex
            ColorPanelBridge.shared.open(color: NSColor(Color(hex: current))) { color in
                store.settings.customThemeColorHex = color.hexString
                store.settings.themeColorMode = .custom
            }
        }
    }
}

private struct SwatchButton<Fill: View>: View {
    var help: String
    var selected: Bool
    var ring: Namespace.ID
    @ViewBuilder var fill: () -> Fill
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            fill()
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                .scaleEffect(hovering ? 1.14 : 1)
                .padding(4)
                .overlay {
                    if selected {
                        Circle().strokeBorder(theme.onSurface.opacity(0.75), lineWidth: 1.5)
                            .matchedGeometryEffect(id: "ring", in: ring)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(SettingsPressStyle())
        .help(help)
        .onHover { hovering = $0 }
        .animation(Motion.lift, value: hovering)
    }
}

@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func open(color: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        onChange?(panel.color)
    }
}

extension NSColor {
    /// `#RRGGBB` in sRGB.
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
    }
}

struct ShortcutGrid: View {
    @Environment(\.theme) private var theme

    private static let items: [(title: String, keys: [String])] = [
        ("播放 / 暂停", ["空格"]),
        ("上一首 / 下一首", ["⌘", "← →"]),
        ("音量加 / 减", ["⌘", "↑ ↓"]),
        ("静音", ["⌥", "⌘", "↓"]),
        ("打开 / 收起播放页", ["⌘", "L"]),
        ("唱歌开 / 关", ["⌥", "⌘", "K"]),
        ("搜索", ["⌘", "K"]),
        ("折叠侧栏", ["⌘", "S"]),
        ("后退", ["⌘", "["]),
        ("定位到正在播放", ["⌥", "⌘", "L"]),
        ("设置", ["⌘", ","]),
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())], alignment: .leading, spacing: 10) {
            ForEach(Self.items, id: \.title) { item in
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.onSurface.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 3) {
                        ForEach(item.keys, id: \.self) { Keycap(label: $0) }
                    }
                }
            }
        }
    }

    private struct Keycap: View {
        var label: String
        @Environment(\.theme) private var theme

        var body: some View {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.onSurface.opacity(0.75))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 20)
                .background(theme.onSurface.opacity(theme.isDark ? 0.08 : 0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(theme.onSurface.opacity(0.1), lineWidth: 0.5)
                }
        }
    }
}

struct AccountCard: View {
    var source: SourceID
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var confirmingLogout = false

    private var name: String { model.displayName(of: source) }
    private var profile: AccountProfile? { model.accounts.profile(of: source) }

    var body: some View {
        ZStack {
            if let profile {
                signedIn(profile).transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                signedOut.transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(Motion.reveal, value: profile?.userID)
        .padding(16)
    }

    private func signedIn(_ profile: AccountProfile) -> some View {
        HStack(spacing: 14) {
            ArtworkView(artwork: profile.avatar, radius: 26, pixelSize: 120)
                .frame(width: 52, height: 52)
                .overlay(Circle().strokeBorder(theme.onSurface.opacity(0.08), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.nickname).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.onSurface).lineLimit(1)
                    if profile.isVIP { Tag(text: "VIP", style: .red, soft: true) }
                }
                Text(["已登录\(name)", profile.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer(minLength: 12)
            if model.hasUserPages(source) {
                SettingsButton(title: "个人主页", systemName: "person") {
                    model.closeSettings()
                    model.openProfile(source)
                }
            }
            if model.accountSource(source)?.account.supportsMultipleAccounts == true {
                SettingsButton(title: "添加账号", systemName: "plus") {
                    Task {
                        if await model.addAccount(source) { model.presentLogin(LoginRequest(source: source, adding: true)) }
                    }
                }
                .disabled(model.accounts.switching.contains(source))
            }
            SettingsButton(title: "退出登录", role: .destructive) { confirmingLogout = true }
                .confirmationDialog("退出\(name)账号？", isPresented: $confirmingLogout) {
                    Button("退出登录", role: .destructive) { Task { await model.logout(source) } }
                } message: {
                    Text("退出后\(name)的歌单和红心不再同步，随时可以重新登录。")
                }
        }
    }

    private var signedOut: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(theme.onSurface.opacity(0.06))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: "person.fill").font(.system(size: 22)).foregroundStyle(theme.onSurfaceVariant.opacity(0.7)))
            VStack(alignment: .leading, spacing: 4) {
                Text("未登录").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.onSurface)
                Text("登录\(name)，\(model.loginBenefits(of: source))")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            SettingsButton(title: "登录", systemName: "person.crop.circle", role: .prominent) { model.presentLogin(LoginRequest(source: source)) }
                .disabled(model.accounts.switching.contains(source))
        }
    }
}

struct KeptAccountRow: View {
    var source: SourceID
    var account: KeptAccount
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var confirmingRemoval = false

    var body: some View {
        let switching = model.accounts.switching.contains(source)
        HStack(spacing: 12) {
            ArtworkView(artwork: account.avatar, radius: 16, pixelSize: 80)
                .frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(theme.onSurface.opacity(0.08), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.nickname).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.onSurface).lineLimit(1)
                    if account.isVIP { Tag(text: "VIP", style: .red, soft: true) }
                }
                if let detail = account.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            SettingsButton(title: "切换", systemName: "arrow.left.arrow.right") {
                Task { await model.switchAccount(source, to: account.userID) }
            }
            IconButton(systemName: "xmark", size: 26, iconSize: 10, variant: .tertiary, help: "移除这个账号") { confirmingRemoval = true }
                .confirmationDialog("移除「\(account.nickname)」？", isPresented: $confirmingRemoval) {
                    Button("移除", role: .destructive) { model.accounts.forget(account.userID, of: source) }
                } message: {
                    Text("之后要用这个账号，需要重新登录。")
                }
        }
        .disabled(switching)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct CacheControl: View {
    var measure: @MainActor () async -> Int64
    var clear: @MainActor () async -> Void
    @Environment(\.theme) private var theme
    @State private var size: Int64?
    @State private var clearing = false
    @State private var cleared = false

    var body: some View {
        HStack(spacing: 12) {
            Text(size.map(Self.format) ?? "…")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.onSurfaceVariant)
                .contentTransition(.numericText(value: Double(size ?? 0)))
            ZStack {
                if cleared {
                    Label("已清除", systemImage: "checkmark")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else {
                    SettingsButton(title: clearing ? "清除中…" : "清除", systemName: "trash") {
                        Task { await run() }
                    }
                    .disabled(clearing || size == 0)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(minWidth: 72, alignment: .trailing)
        }
        .task { size = await measure() }
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    private func run() async {
        clearing = true
        await clear()
        let after = await measure()
        withAnimation(Motion.reveal) {
            size = after
            clearing = false
            cleared = true
        }
        try? await Task.sleep(for: .seconds(1.6))
        withAnimation(Motion.reveal) { cleared = false }
    }
}

struct ForgetControl: View {
    var unit: String
    var count: () -> Int
    var forget: () -> Void
    @Environment(\.theme) private var theme
    @State private var shown: Int?
    @State private var confirming = false

    var body: some View {
        let value = shown ?? count()
        HStack(spacing: 12) {
            Text("\(value) \(unit)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.onSurfaceVariant)
                .contentTransition(.numericText(value: Double(value)))
            SettingsButton(title: "清除", systemName: "trash") { confirming = true }
                .disabled(value == 0)
                .confirmationDialog("清除全部歌词时间调整？", isPresented: $confirming) {
                    Button("清除", role: .destructive) {
                        forget()
                        withAnimation(Motion.reveal) { shown = count() }
                    }
                } message: {
                    Text("手动或校准得到的偏移都会忘掉，歌词回到原本的时间。")
                }
        }
    }
}

struct AboutHeader: View {
    @Environment(\.theme) private var theme
    @State private var shown = false

    static let repository = URL(string: "https://github.com/Mrs4s/StarryPlayer")!

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        HStack(spacing: 16) {
            AppMark(size: 60)
                .shadow(color: AppMark.night.opacity(0.3), radius: 8, y: 4)
                .reveal(shown, distance: 0, scale: 0.7)
            VStack(alignment: .leading, spacing: 4) {
                Text("Starry Player").font(.system(size: 18, weight: .bold)).foregroundStyle(theme.onSurface)
                Text("版本 \(Self.version)").font(.system(size: 12.5)).foregroundStyle(theme.onSurfaceVariant)
                Text("为 macOS 打造的音乐播放器").font(.system(size: 12.5)).foregroundStyle(theme.onSurfaceVariant)
            }
            .reveal(shown, delay: 0.08, distance: 6)
            Spacer(minLength: 0)
        }
        .padding(18)
        .onAppear { shown = true }
    }
}
