import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var direction: CGFloat = 1
    @State private var revealing = false
    @State private var revealTask: Task<Void, Never>?
    @State private var shown = false
    @Namespace private var selection

    static let railWidth: CGFloat = 216

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let advanced = model.showsAdvancedSettings
        let catalog = SettingsCatalog(model: model)
        HStack(spacing: 0) {
            rail(catalog: catalog, advanced: advanced)
                .frame(width: Self.railWidth)
                .frame(maxHeight: .infinity)
                .background(theme.onSurface.opacity(theme.isDark ? 0.025 : 0.02))
            Rectangle()
                .fill(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.06))
                .frame(width: 1)
            content(catalog: catalog, advanced: advanced)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.surface)
        .tint(theme.accent)
        .environment(\.settingsRevealing, revealing)
        .background {
            // Esc: first clears the search, then closes. A key equivalent, so it works whatever
            // has the focus.
            Button("") {
                if query.isEmpty { close() } else { query = "" }
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            if !catalog.isListed(model.settingsPage, advanced: advanced) { model.settingsPage = .app(.general) }
            shown = true
        }
        .onDisappear { revealTask?.cancel() }
    }

    static let titleBarHeight: CGFloat = 46

    private func rail(catalog: SettingsCatalog, advanced: Bool) -> some View {
        let pages = catalog.pages.filter { catalog.isListed($0, advanced: advanced) }
        let appPages = pages.filter { if case .app = $0 { true } else { false } }
        let sourcePages = pages.filter { if case .source = $0 { true } else { false } }
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: Self.titleBarHeight)
                .contentShape(Rectangle())
                .modifier(WindowDrag())
            SearchField(text: $query, placeholder: "搜索设置", width: Self.railWidth - 30, focusedWidth: Self.railWidth - 30)
                .reveal(shown, delay: 0.03, distance: 4)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(appPages.enumerated()), id: \.element) { index, page in
                    railItem(page, catalog: catalog, delay: 0.05 + Double(index) * 0.025)
                }
                if !sourcePages.isEmpty {
                    Text("音乐平台")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                        .padding(.leading, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .reveal(shown, delay: 0.05 + Double(appPages.count) * 0.025, distance: 6)
                        .transition(.opacity)
                }
                ForEach(Array(sourcePages.enumerated()), id: \.element) { index, page in
                    railItem(page, catalog: catalog, delay: 0.05 + Double(appPages.count + 1 + index) * 0.025)
                }
            }
            .padding(.top, 14)
            Spacer(minLength: 12)
            advancedSwitch(on: advanced)
                .reveal(shown, delay: 0.22, distance: 4)
            Text("Starry Player \(AboutHeader.version)")
                .font(.system(size: 11))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
                .padding(.leading, 10)
                .padding(.top, 10)
                .reveal(shown, delay: 0.24, distance: 0)
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 16)
        .animation(Motion.selection, value: model.settingsPage)
        .animation(Motion.selection, value: trimmedQuery.isEmpty)
    }

    private func railItem(_ page: SettingsPage, catalog: SettingsCatalog, delay: Double) -> some View {
        SettingsRailItem(info: catalog.info(for: page), active: trimmedQuery.isEmpty && model.settingsPage == page, selection: selection) {
            select(page, in: catalog)
        }
        .zIndex(model.settingsPage == page ? 1 : 0)
        .reveal(shown, delay: delay, distance: 6)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
    }

    private func advancedSwitch(on: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(on ? theme.accent : theme.onSurface.opacity(0.6))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("高级设置")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.onSurface)
                Text(on ? "显示全部选项" : "更多细节选项")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding { on } set: { setAdvanced($0) })
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(on ? theme.accent.opacity(theme.isDark ? 0.14 : 0.1) : theme.onSurface.opacity(theme.isDark ? 0.05 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { setAdvanced(!on) }
        .animation(Motion.hover, value: on)
        .help("显示歌词排版、背景细节、歌词来源顺序、代理等更细的选项")
    }

    @ViewBuilder
    private func content(catalog: SettingsCatalog, advanced: Bool) -> some View {
        let text = trimmedQuery
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                let page = model.settingsPage
                SettingsPageView(info: catalog.info(for: page), groups: catalog.groups(for: page).compactMap { $0.visible(advanced: advanced) })
                    .id(page)
                    .transition(pageTransition)
            } else {
                SettingsSearchResults(query: text, sections: search(text, in: catalog), tagsAdvanced: !advanced) { select($0, in: catalog) }
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        }
        .environment(\.settingsQuery, text)
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: 28)
                .contentShape(Rectangle())
                .modifier(WindowDrag())
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.15)) }
        return .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .offset(y: 18 * direction)).animation(Motion.tab),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.1))
        )
    }

    private func search(_ text: String, in catalog: SettingsCatalog) -> [SettingsSearchResults.Section] {
        let terms = text.lowercased().split(separator: " ").map(String.init)
        let compact = terms.joined()
        let latin = compact.allSatisfy { $0.isASCII && $0.isLetter }
        var sections: [SettingsSearchResults.Section] = []
        for page in catalog.pages {
            let info = catalog.info(for: page)
            var entries: [SettingsEntry] = []
            for group in catalog.groups(for: page) {
                for var entry in group.entries {
                    let words = [info.title, group.title ?? "", entry.title, entry.detail ?? "", entry.keywords].joined(separator: " ").lowercased()
                    let found = terms.allSatisfy { words.contains($0) } || (latin && compact.count >= 2 && Self.pinyin(entry.title).contains(compact))
                    guard found else { continue }
                    entry.advanced = entry.advanced || group.advanced
                    entries.append(entry)
                }
            }
            if !entries.isEmpty {
                sections.append(.init(page: page, info: info, group: SettingsGroup("search.\(page.id)", entries: entries)))
            }
        }
        return sections
    }

    private static func pinyin(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? text
        return latin.lowercased().filter { !$0.isWhitespace }
    }

    private func select(_ page: SettingsPage, in catalog: SettingsCatalog) {
        let all = catalog.pages
        let from = all.firstIndex(of: model.settingsPage) ?? 0
        let to = all.firstIndex(of: page) ?? 0
        direction = to >= from ? 1 : -1
        query = ""
        // A text field on the old page must not keep the keystrokes.
        NSApp.keyWindow?.makeFirstResponder(nil)
        model.settingsPage = page
    }

    private func setAdvanced(_ on: Bool) {
        guard on != model.showsAdvancedSettings else { return }
        revealTask?.cancel()
        revealing = on
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.fold) {
            model.showsAdvancedSettings = on
            if !on, !SettingsCatalog(model: model).isListed(model.settingsPage, advanced: false) {
                direction = -1
                model.settingsPage = .app(.general)
            }
        }
        guard on else { return }
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            revealing = false
        }
    }

    private func close() {
        model.closeSettings()
    }
}

/// A rail row: 32 pt, a 20 pt symbol and a 13 pt title. The selected one carries the accent pill
/// (shared, so it slides) and the filled symbol; a click dips the symbol and springs it back.
private struct SettingsRailItem: View {
    var info: SettingsPageInfo
    var active: Bool
    var selection: Namespace.ID
    var action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var clicks = 0

    var body: some View {
        Button {
            clicks += 1
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: info.icon)
                    .symbolVariant(active ? .fill : .none)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(active ? theme.accent : theme.onSurface.opacity(hovering ? 0.8 : 0.6))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20)
                    .keyframeAnimator(initialValue: 1.0, trigger: clicks) { content, scale in
                        content.scaleEffect(reduceMotion ? 1 : scale)
                    } keyframes: { _ in
                        KeyframeTrack(\.self) {
                            CubicKeyframe(0.8, duration: 0.08)
                            SpringKeyframe(1, duration: 0.45, spring: .bouncy)
                        }
                    }
                Text(info.title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(theme.onSurface.opacity(active ? 1 : 0.82))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background { background }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(SettingsPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if active {
            shape.fill(theme.accent.opacity(theme.isDark ? 0.16 : 0.12))
                .matchedGeometryEffect(id: "settings.selection", in: selection)
        } else if hovering {
            shape.fill(theme.onSurface.opacity(0.05))
        }
    }
}

private struct SettingsPageView: View {
    var info: SettingsPageInfo
    var groups: [SettingsGroup]
    @Environment(\.theme) private var theme
    @State private var shown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    SettingsGroupView(group: group)
                        .reveal(shown, delay: 0.02 + Double(min(index, 8)) * 0.035, distance: 10)
                        .transition(.settingsEntry)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 30)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .onAppear { shown = true }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.accent.opacity(theme.isDark ? 0.18 : 0.13))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: info.icon)
                        .symbolVariant(.fill)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(theme.accent)
                }
                .reveal(shown, distance: 0, scale: 0.8)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.onSurface)
                Text(info.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .reveal(shown, delay: 0.03, distance: 6)
        }
    }
}

private struct SettingsSearchResults: View {
    struct Section {
        var page: SettingsPage
        var info: SettingsPageInfo
        var group: SettingsGroup
    }

    var query: String
    var sections: [Section]
    var tagsAdvanced: Bool
    var open: (SettingsPage) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let count = sections.reduce(0) { $0 + $1.group.entries.count }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("搜索结果")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(theme.onSurface)
                    Text("\(count) 项")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(theme.onSurfaceVariant)
                        .contentTransition(.numericText(value: Double(count)))
                        .opacity(count == 0 ? 0 : 1)
                }
                .padding(.top, 8)
                if sections.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(theme.onSurfaceVariant.opacity(0.5))
                        Text("没有找到与“\(query)”有关的设置")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.onSurface)
                        Text("换个说法试试，比如“歌词”“深色”“音质”")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                    .transition(.opacity)
                }
                ForEach(sections, id: \.page) { section in
                    SettingsGroupView(group: section.group, tagsAdvanced: tagsAdvanced, header: AnyView(PageLink(info: section.info) { open(section.page) }))
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 30)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.listEdit, value: sections.map { $0.group.entries.map(\.id) })
        }
        .scrollIndicators(.automatic)
    }

    private struct PageLink: View {
        var info: SettingsPageInfo
        var action: () -> Void
        @Environment(\.theme) private var theme
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: info.icon).font(.system(size: 11, weight: .semibold))
                    Text(info.title).font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .offset(x: hovering ? 2 : 0)
                }
                .foregroundStyle(hovering ? theme.onSurface : theme.onSurfaceVariant)
                .padding(.leading, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .help("打开“\(info.title)”")
        }
    }
}
