import SwiftUI

@main
struct StarryPlayerApp: App {
    #if DEVTOOLS
    @State private var model = DevTools.makeModel()
    #else
    @State private var model = AppModel()
    #endif
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: Metrics.windowMinSize.width, minHeight: Metrics.windowMinSize.height)
                .preferredColorScheme(model.preferredColorScheme)
                .onAppear { appDelegate.model = model }
        }
        // Opened files go to the window there is (`AppDelegate`), not a new one.
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1280, height: 800)
        // Commands must not observe player or navigation state: scene updates force
        // the whole view tree to refresh and delay Now Playing transitions.
        .commands {
            let localization = model.localization
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(localization.string(LocalizedStringResource("menu.checkUpdates", defaultValue: "检查更新…"))) { model.checkForUpdates() }
            }
            CommandMenu(localization.string(LocalizedStringResource("menu.playback", defaultValue: "播放"))) {
                Button(localization.string(LocalizedStringResource("menu.togglePlay", defaultValue: "播放/暂停"))) { model.player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button(localization.string(LocalizedStringResource("menu.next", defaultValue: "下一曲"))) { model.player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button(localization.string(LocalizedStringResource("menu.previous", defaultValue: "上一曲"))) { model.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button(localization.string(LocalizedStringResource("menu.volumeUp", defaultValue: "增大音量"))) { model.player.stepVolume(up: true) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button(localization.string(LocalizedStringResource("menu.volumeDown", defaultValue: "减小音量"))) { model.player.stepVolume(up: false) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button(localization.string(LocalizedStringResource("menu.mute", defaultValue: "静音/取消静音"))) { model.player.toggleMute() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button(localization.string(LocalizedStringResource("menu.vocals", defaultValue: "唱歌开/关"))) { model.player.toggleVocalAttenuation() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                Button(localization.string(LocalizedStringResource("menu.vocalsUp", defaultValue: "增大人声"))) { if model.player.vocalAttenuationEnabled { model.player.stepVocalLevel(up: true) } }
                Button(localization.string(LocalizedStringResource("menu.vocalsDown", defaultValue: "减小人声"))) { if model.player.vocalAttenuationEnabled { model.player.stepVocalLevel(up: false) } }
                Divider()
                Button(localization.string(LocalizedStringResource("menu.nowPlaying", defaultValue: "打开/收起播放页"))) {
                    model.player.showNowPlaying.toggle()
                }
                .keyboardShortcut("l", modifiers: .command)
                Button(localization.string(LocalizedStringResource("menu.lyrics", defaultValue: "播放页：歌词"))) { model.showNowPlaying(.lyrics) }
                    .keyboardShortcut("1", modifiers: .command)
                Button(localization.string(LocalizedStringResource("menu.comments", defaultValue: "播放页：评论"))) { model.showNowPlaying(.comments) }
                    .keyboardShortcut("2", modifiers: .command)
                Button(localization.string(LocalizedStringResource("menu.queue", defaultValue: "播放页：播放队列"))) { model.showNowPlaying(.queue) }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button(localization.string(LocalizedStringResource("menu.desktopLyrics", defaultValue: "桌面歌词开/关"))) { model.showsDesktopLyrics.toggle() }
                Button(localization.string(LocalizedStringResource("menu.lockDesktopLyrics", defaultValue: "锁定/解锁桌面歌词"))) { model.desktopLyricsLocked.toggle() }
                Button(localization.string(LocalizedStringResource("menu.editLyrics", defaultValue: "编辑歌词…"))) {
                    if let track = model.player.current { model.presentLyricsEditor(for: track) }
                }
            }
            CommandGroup(before: .sidebar) {
                Button(localization.string(LocalizedStringResource("menu.sidebar", defaultValue: "切换侧栏"))) { model.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            CommandMenu(localization.string(LocalizedStringResource("menu.go", defaultValue: "前往"))) {
                Button(localization.string(LocalizedStringResource("menu.search", defaultValue: "搜索"))) { model.openSearch() }
                    .keyboardShortcut("k", modifiers: .command)
                Button(localization.string(LocalizedStringResource("menu.back", defaultValue: "后退"))) { model.back() }
                    .keyboardShortcut("[", modifiers: .command)
                Button(localization.string(LocalizedStringResource("menu.refresh", defaultValue: "刷新当前页面"))) { model.refreshCurrentPage() }
                    .keyboardShortcut("r", modifiers: .command)
                Button(localization.string(LocalizedStringResource("menu.locate", defaultValue: "定位到正在播放的歌曲"))) { model.locatePlaying() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
            CommandGroup(after: .appSettings) {
                Button(localization.string(LocalizedStringResource("menu.settings", defaultValue: "设置…"))) { model.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
