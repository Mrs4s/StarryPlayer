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
            CommandGroup(replacing: .newItem) {}
            CommandMenu("播放") {
                Button("播放/暂停") { model.player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("下一曲") { model.player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("上一曲") { model.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("增大音量") { model.player.stepVolume(up: true) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("减小音量") { model.player.stepVolume(up: false) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("静音/取消静音") { model.player.toggleMute() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("唱歌开/关") { model.player.toggleVocalAttenuation() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                Button("增大人声") { if model.player.vocalAttenuationEnabled { model.player.stepVocalLevel(up: true) } }
                Button("减小人声") { if model.player.vocalAttenuationEnabled { model.player.stepVocalLevel(up: false) } }
                Divider()
                Button("打开/收起播放页") {
                    model.player.showNowPlaying.toggle()
                }
                .keyboardShortcut("l", modifiers: .command)
                Button("播放页：歌词") { model.showNowPlaying(.lyrics) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("播放页：评论") { model.showNowPlaying(.comments) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("播放页：播放队列") { model.showNowPlaying(.queue) }
                    .keyboardShortcut("3", modifiers: .command)
            }
            CommandGroup(before: .sidebar) {
                Button("切换侧栏") { model.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            CommandMenu("前往") {
                Button("搜索") { model.openSearch() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("后退") { model.back() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("定位到正在播放的歌曲") { model.locatePlaying() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
            CommandGroup(after: .appSettings) {
                Button("设置…") { model.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
