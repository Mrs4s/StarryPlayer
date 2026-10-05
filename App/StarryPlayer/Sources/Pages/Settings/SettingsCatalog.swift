import AppKit
import AudioProcessing
import Library
import LocalLibrary
import LyricsProviders
import MusicSources
import StarryCore
import SwiftUI

@MainActor
struct SettingsCatalog {
    let model: AppModel

    private var store: SettingsStore { model.settings }
    private var settings: AppSettings { model.settings.settings }

    var pages: [SettingsPage] {
        SettingsCategory.allCases.map(SettingsPage.app) + model.registry.sources.filter { $0.supports((any ConfigurableSource).self) || Self.hasQualityChoice($0) }.map { .source($0.id) }
    }

    func groups(for page: SettingsPage) -> [SettingsGroup] {
        switch page {
        case .app(let category):
            return groups(for: category)
        case .source(let id):
            guard let source = model.registry.source(for: id) else { return [] }
            let own = id == .local ? localGroups : []
            return own + qualityGroups(source) + (source.capability((any ConfigurableSource).self).map(sourceGroups) ?? [])
        }
    }

    func isListed(_ page: SettingsPage, advanced: Bool) -> Bool {
        guard case .source = page else { return true }
        return groups(for: page).contains { $0.visible(advanced: advanced) != nil }
    }

    func info(for page: SettingsPage) -> SettingsPageInfo {
        switch page {
        case .app(let category):
            return SettingsPageInfo(title: category.title, icon: category.icon, summary: category.summary)
        case .source(let id):
            let source = model.configurableSources.first { $0.id == id }
            let quality = model.registry.source(for: id).map(Self.hasQualityChoice) == true ? "音质" : nil
            let summary = [quality, source?.settingsSummary].compactMap { $0 }.joined(separator: "，")
            // A plugin with no settings of its own (Jellyfin: only quality) still has its icon.
            return SettingsPageInfo(title: model.displayName(of: id), icon: model.sourceSymbol(of: id), summary: summary)
        }
    }

    private func groups(for category: SettingsCategory) -> [SettingsGroup] {
        switch category {
        case .general: general
        case .appearance: appearance
        case .playback: playback
        case .nowPlaying: nowPlaying
        case .lyrics: lyrics
        case .account: account
        case .storage: storage
        case .plugins: pluginsPage
        case .about: about
        }
    }

    private var general: [SettingsGroup] {
        [
            SettingsGroup("launch", title: "启动", entries: [
                toggle("restorePlayback", "启动时恢复上次播放", "打开应用时回到上次听的歌和进度，不会自动开始播放", \.restorePlayback, keywords: "队列 进度 继续"),
            ]),
            SettingsGroup("shortcuts", title: "快捷键", entries: [
                SettingsEntry("shortcuts", "键盘快捷键", keywords: "快捷键 键盘 shortcut 空格", layout: .block) { ShortcutGrid() },
            ]),
        ]
    }

    private var appearance: [SettingsGroup] {
        var theme: [SettingsEntry] = [
            SettingsEntry("appearance", "外观", keywords: "深色 浅色 暗色 夜间 dark light 主题", layout: .block) {
                VisualPicker(selection: bind(\.appearance), options: AppSettings.Appearance.allCases.map { appearance in
                    .init(value: appearance, title: Self.appearanceName(appearance)) { _ in AnyView(AppearancePreview(appearance: appearance)) }
                })
            },
            SettingsEntry("themeColor", "主题色", detail: themeColorDetail, keywords: "颜色 强调色 封面 自定义 accent") { ThemeColorSwatches() },
        ]
        if settings.themeColorMode == .custom {
            theme.append(SettingsEntry("themeColorHex", "颜色值", detail: "十六进制，如 #FE7971", keywords: "hex 自定义颜色", advanced: true) {
                SettingsTextField(text: bind(\.customThemeColorHex), placeholder: "#FE7971", width: 110)
            })
        }
        return [
            SettingsGroup("theme", title: "主题", entries: theme),
            SettingsGroup("layout", title: "布局", entries: [
                SettingsEntry("sidebarMode", "侧栏", detail: sidebarModeDetail, keywords: "侧边栏 浮动 隐藏 停靠 ⌘S", layout: .block) {
                    VisualPicker(selection: bind(\.sidebarMode), options: AppSettings.SidebarMode.allCases.map { mode in
                        .init(value: mode, title: Self.sidebarModeName(mode)) { hovering in AnyView(SidebarModePreview(mode: mode, hovering: hovering)) }
                    })
                },
                playerBarStyle,
            ]),
        ]
    }

    private var playerBarStyle: SettingsEntry {
        var glassAvailable = false
        if #available(macOS 26, *) { glassAvailable = true }
        return SettingsEntry("playerBarStyle", "播放栏", detail: glassAvailable ? (settings.playerBarStyle == .glass ? "透出页面的玻璃胶囊，进度是沿边缘流动的光" : "窗口底部的磨砂播放栏") : "液态玻璃需要 macOS 26 或更新版本", keywords: "液态玻璃 glass 底栏", layout: .block) {
            VisualPicker(selection: glassAvailable ? bind(\.playerBarStyle) : .constant(.classic), options: AppSettings.PlayerBarStyle.allCases.map { style in
                .init(value: style, title: style == .classic ? "经典" : "液态玻璃") { hovering in AnyView(PlayerBarPreview(style: style, hovering: hovering)) }
            })
            .disabled(!glassAvailable)
        }
    }

    private var playback: [SettingsGroup] {
        let player = model.player
        return [
            SettingsGroup("quality", title: "音质", entries: [
                SettingsEntry("quality", "音质", detail: "各音乐平台可在自己的设置页另选；实际音质取决于歌曲版本与会员权限", keywords: "无损 hi-res 高品质 码率") {
                    SettingsMenu(selection: bind(\.preferredQuality), options: AudioQuality.allCases.map { ($0, $0.displayName) })
                },
                toggle("trial", "播放试听片段", "会员歌曲无法完整播放时，先听 30 秒", \.allowTrialPlay, keywords: "vip 试听"),
            ]),
            SettingsGroup("output", title: "输出", entries: [
                SettingsEntry("outputDevice", "输出设备", detail: outputDetail, keywords: "扬声器 耳机 声卡 dac 音频 设备") {
                    SettingsMenu(selection: outputBinding, options: outputOptions, width: 230)
                },
            ]),
            SettingsGroup("transition", title: "切歌", footer: "只在一首歌自然播完时生效；手动切歌仍然直接切换。", entries: transitionEntries),
            SettingsGroup("loudness", title: "音量均衡", footer: "按歌曲里的 ReplayGain 信息调整音量，让不同的歌听起来一样响；没有这项信息的歌音量不变。", entries: loudnessEntries),
            SettingsGroup("equalizer", title: "均衡器", entries: [
                SettingsEntry("equalizer", "均衡器", detail: "十段均衡，在播放页底栏音量旁的按钮里调整各频段", keywords: "eq 音效 低音 高音 频段 增益") {
                    SettingsSwitch(isOn: Binding { player.equalizer.isEnabled } set: { player.setEqualizerEnabled($0) })
                },
                SettingsEntry("equalizerPreset", "预设", detail: "选一个预设也会打开均衡器", keywords: "eq 流行 摇滚 古典 爵士 电子 人声 低音增强") {
                    SettingsMenu(selection: Binding { player.equalizer.presetID } set: { player.selectEqualizerPreset($0) }, options: EqualizerPreset.all.map { ($0.id, $0.name) } + [(EqualizerPreset.customID, "自定义")])
                },
            ]),
            SettingsGroup("vocals", title: "唱歌", entries: [
                SettingsEntry("vocals", "唱歌", detail: "降低原唱人声，跟着伴奏一起唱", keywords: "伴奏 卡拉ok karaoke 人声 消音") {
                    SettingsSwitch(isOn: Binding { player.vocalAttenuationEnabled } set: { player.setVocalAttenuation($0) })
                },
                SettingsEntry("vocalLevel", "保留人声", detail: "开启唱歌时，原唱的声音留多少", keywords: "人声音量 伴奏") {
                    SettingsSlider(value: Binding { player.vocalLevel } set: { player.setVocalLevel($0) }, range: VocalAttenuationCurve.sliderRange, step: 1) { "\(Int($0))%" }
                },
                SettingsEntry("vocalModel", "分离模型", detail: vocalModelDetail, keywords: "模型 AUSoundIsolation 人声隔离", advanced: true, layout: .block) {
                    VocalModelButtons()
                },
            ]),
            SettingsGroup("loading", title: "加载", advanced: true, entries: [
                toggle("preload", "预加载下一首", "快结束时提前准备下一首，切歌更快", \.preloadNextTrack, keywords: "缓冲"),
            ]),
        ]
    }

    private var transitionEntries: [SettingsEntry] {
        var entries = [
            toggle("gapless", "无缝播放", "上一首播完的同一刻接上下一首，中间没有停顿", \.transition.gapless, keywords: "gapless 无缝衔接 间隙 停顿 连续播放"),
            toggle("crossfade", "交叉淡入淡出", "上一首渐弱的同时下一首渐强", \.transition.crossfade, keywords: "crossfade 淡入 淡出 过渡 混音"),
        ]
        if settings.transition.crossfade {
            entries.append(slider("crossfadeSeconds", "淡化时长", nil, \.transition.crossfadeSeconds, TransitionMode.crossfadeRange, step: 1, format: { "\(Int($0)) 秒" }, keywords: "crossfade 淡入淡出 秒"))
            entries.append(toggle("albumsWithoutFade", "同一张专辑不淡化", "专辑里前后相连的歌照原样衔接，适合现场和概念专辑", \.transition.albumsWithoutFade, keywords: "专辑 现场 live 无缝"))
        }
        return entries
    }

    private var loudnessEntries: [SettingsEntry] {
        var entries = [
            SettingsEntry("loudness", "音量均衡", detail: "按专辑时，同一张专辑里的歌保持原有的响度差别", keywords: "replaygain 响度 音量 标准化 normalize 增益") {
                SettingsMenu(selection: bind(\.loudness.mode), options: [(Loudness.Mode.off, "关闭"), (.track, "按单曲"), (.album, "按专辑")])
            },
        ]
        if settings.loudness.mode != .off {
            entries.append(SettingsEntry("loudnessPreamp", "增益调整", detail: "在标签给出的增益上整体加减；太大时会被限制在不失真的范围内", keywords: "replaygain 前置增益 preamp") {
                SettingsSlider(value: bind(\.loudness.preamp), range: -6...12, step: 0.5) { String(format: "%+.1f dB", $0) }
            })
        }
        return entries
    }

    private var nowPlaying: [SettingsGroup] {
        nowPlayingBasics + nowPlayingDetails
    }

    private var nowPlayingBasics: [SettingsGroup] {
        let advanced = model.showsAdvancedSettings
        var lyricEntries: [SettingsEntry] = []
        if !advanced {
            lyricEntries.append(SettingsEntry("lyricSize", "歌词大小", detail: "随窗口自动缩放，可在此基础上调大调小", keywords: "字号 字体 缩放") {
                SettingsSlider(value: lyricSizeBinding, range: 0.6...1.6, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
            })
        }
        lyricEntries += [
            SettingsEntry("lyricAlignment", "对齐", keywords: "居中 靠左") {
                SegmentSwitch(selection: bind(\.lyrics.alignment), options: [(.leading, "靠左"), (.center, "居中")])
            },
            toggle("translation", "显示翻译", "外文歌词下方显示中文翻译", \.lyrics.showTranslation, keywords: "译文"),
            toggle("romanization", "显示音译", "为日语、韩语等歌词标注读音", \.lyrics.showRomanization, keywords: "注音 罗马音 拼音 读音"),
            toggle("perSyllable", "逐字点亮", "随演唱进度一个字一个字亮起（需要逐字歌词）", \.lyrics.perSyllable, keywords: "逐字 卡拉ok"),
            SettingsEntry("blurLines", "模糊其他行", detail: "只让正在唱的那一行保持清晰", keywords: "模糊 聚焦") {
                SettingsSwitch(isOn: Binding { store.settings.lyrics.blurMode != .off } set: { store.settings.lyrics.blurMode = $0 ? .both : .off })
            },
        ]
        var background: [SettingsEntry] = [
            SettingsEntry("backgroundStyle", "背景", detail: backgroundDetail, keywords: "封面 模糊 渐变 流动") {
                SegmentSwitch(selection: bind(\.background.style), options: [(.artwork, "流动封面"), (.blur, "模糊封面"), (.gradient, "渐变")])
            },
        ]
        if settings.background.style == .artwork {
            background.append(SettingsEntry("backgroundMotion", "随音乐律动", detail: "自动：显示歌词时跟着节奏起伏", keywords: "动态 律动 节奏") {
                SegmentSwitch(selection: bind(\.background.motion), options: [(.auto, "自动"), (.calm, "平静"), (.lively, "律动")])
            })
        }
        return [
            SettingsGroup("lyricsLook", title: "歌词", entries: lyricEntries),
            SettingsGroup("background", title: "背景", entries: background),
        ]
    }

    private var nowPlayingDetails: [SettingsGroup] {
        let percent: (Double) -> String = { String(format: "%.2f×", $0) }
        let rates = [15, 24, 30, 60, 120].map { ($0, "\($0) fps") }
        return [
            SettingsGroup("lyricLayout", title: "歌词排版", footer: "窗口和全屏各用一套预设。数值为 0 时使用预设。", advanced: true, entries: [
                slider("windowedScale", "窗口缩放", "窗口预设：48 pt 粗体，行距 40", \.lyrics.windowedScale, 0.5...2, step: 0.05, format: percent, keywords: "歌词大小 预设"),
                slider("fullscreenScale", "全屏缩放", "全屏预设：当前行居中，按 1080 pt 画布设计", \.lyrics.fullscreenScale, 0.5...3, step: 0.05, format: percent, keywords: "歌词大小 预设"),
                toggle("autoScale", "随窗口高度缩放", nil, \.lyrics.autoScale),
                slider("fontSize", "字号", nil, \.lyrics.fontSize, 0...96, step: 1, format: { $0 == 0 ? "预设" : "\(Int($0)) pt" }),
                slider("lineSpacing", "行距", nil, \.lyrics.lineSpacing, 0...80, step: 1, format: { $0 == 0 ? "预设" : "\(Int($0)) pt" }),
                menu("anchor", "当前行位置", nil, \.lyrics.anchor, [(.preset, "跟随预设"), (.top, "靠上"), (.center, "居中")]),
                slider("inactiveOpacity", "其他行不透明度", nil, \.lyrics.inactiveOpacity, 0...0.8, step: 0.005, format: { $0 == 0 ? "预设" : String(format: "%.2f", $0) }),
                toggle("hoverHighlight", "悬停高亮", "指针所在的行变亮，点击跳到那里", \.lyrics.hoverHighlight),
            ]),
            SettingsGroup("lyricEffects", title: "歌词特效", advanced: true, entries: [
                toggle("spring", "弹簧换行", "mass 1 · stiffness 100 · damping 18，逐行错开", \.lyrics.spring),
                toggle("lift", "音节上浮", "唱到的字上浮 2 pt", \.lyrics.lift),
                toggle("emphasis", "重音放大", "长音 1.00 → 1.14", \.lyrics.emphasis),
                toggle("glow", "辉光", "长音发光，半径 5", \.lyrics.glow),
                menu("blurMode", "模糊范围", nil, \.lyrics.blurMode, [(.off, "关闭"), (.upcoming, "仅后面的行"), (.both, "前后的行")]),
                slider("blurRadius", "模糊半径", "每隔一行增加的模糊", \.lyrics.blurRadius, 0...8, step: 0.1, format: { String(format: "%.1f", $0) }),
                slider("blurMax", "模糊上限", nil, \.lyrics.blurMax, 0...12, step: 0.1, format: { String(format: "%.1f", $0) }),
            ]),
            SettingsGroup("backgroundDetails", title: "背景细节", footer: "1.00× 为默认数值。", advanced: true, entries: [
                slider("speed", "旋转速度", nil, \.background.speed, 0...3, step: 0.05, format: percent),
                slider("blurScale", "模糊", "平静 160 / 200 pt，律动 85 / 120 pt", \.background.blurScale, 0.25...2, step: 0.05, format: percent),
                slider("saturation", "饱和度", "平静 2.4 / 2.9，律动 2.0 / 2.4", \.background.saturationScale, 0...2, step: 0.05, format: percent),
                slider("brightness", "亮度", nil, \.background.brightness, 0.2...2, step: 0.05, format: { String(format: "%.2f", $0) }),
                slider("scrim", "压暗", "黑色遮罩", \.background.scrim, 0...0.9, step: 0.01, format: { String(format: "%.2f", $0) }),
                slider("whiteScrim", "提亮", "白色遮罩", \.background.whiteScrim, 0...0.4, step: 0.01, format: { String(format: "%.2f", $0) }),
                slider("audioReactivity", "跟随音乐强度", nil, \.background.audioReactivity, 0...3, step: 0.05, format: percent),
                slider("pinch", "律动扭曲", nil, \.background.pinchStrength, 0...1, step: 0.05, format: percent),
                toggle("colorGrade", "色彩分级", "用调色表收敛过艳的红与蓝", \.background.colorGrade),
                menu("fps", "帧率", "越高越流畅，也越耗电", \.background.framesPerSecond, rates),
                menu("fullscreenFps", "全屏帧率", nil, \.background.fullscreenFramesPerSecond, rates),
            ]),
            SettingsGroup("nowPlayingReset", advanced: true, entries: [
                SettingsEntry("nowPlayingReset", "恢复播放页默认设置", detail: "歌词与背景的所有选项回到初始值", keywords: "重置", advanced: true) {
                    SettingsButton(title: "恢复默认", systemName: "arrow.counterclockwise") {
                        withAnimation(Motion.reveal) {
                            store.settings.lyrics = AppSettings.Lyrics()
                            store.settings.background = AppSettings.Background()
                        }
                    }
                },
            ]),
        ]
    }

    var popoverGroups: [SettingsGroup] {
        var source: [SettingsEntry] = [preferTrackPlatform]
        if let current = currentLyrics(compact: true) {
            source.append(current)
        }
        return [SettingsGroup("popoverSource", title: "歌词来源", entries: source)] + nowPlaying
    }

    private var lyrics: [SettingsGroup] {
        let sources: [SettingsEntry] = [
            toggle("amll", "社区逐字歌词", "有 AMLL 社区制作的逐音节歌词时，总是用它", \.amllDbEnabled, keywords: "amll ttml 逐字 逐音节"),
            preferTrackPlatform,
            SettingsEntry("sourceOrder", "平台顺序", detail: "排在前面的平台先查，第一个有逐字歌词的胜出，都只有逐行歌词时用最前面的；关闭的平台不参与查找，其他平台的歌曲按标题、歌手和时长匹配", keywords: "qq 酷狗 网易云 优先级 来源顺序", layout: .block) {
                PriorityList(entries: model.lyricProviderIDs.map { .init(id: $0.rawValue, title: $0.displayName, detail: providerDetail($0)) }, order: bind(\.lyricSourceOrder), allowsDisabling: true)
            },
            toggle("stripCredits", "隐藏制作信息", "去掉开头的「作词」「作曲」等信息行", \.stripLyricCredits, keywords: "作词 作曲 制作人"),
        ]
        var lookup: [SettingsEntry] = [
            toggle("race", "同时查询所有平台", "更快，但请求更多；选出的歌词不变", \.lyricRaceProviders, keywords: "并发 智能优选"),
        ]
        if settings.amllDbEnabled {
            lookup.append(SettingsEntry("amllServer", "AMLL 数据库地址", detail: "基础地址，或含 %p（平台目录）与 %s（歌曲 id）的模板", keywords: "服务器 镜像") {
                SettingsTextField(text: bind(\.amllDbServer), placeholder: AMLLDatabase.defaultTemplate)
            })
        }
        lookup.append(SettingsEntry("localTTML", "本地 TTML 歌词库", detail: settings.localLyricRepository ?? "包含 .ttml 文件的文件夹，命中时优先于所有在线歌词", keywords: "本地 文件夹 ttml") {
            HStack(spacing: 8) {
                if settings.localLyricRepository != nil {
                    SettingsButton(title: "移除") { store.settings.localLyricRepository = nil }
                }
                SettingsButton(title: "选择…", systemName: "folder") { chooseLyricFolder() }
            }
        })
        var groups: [SettingsGroup] = []
        if let current = currentLyrics(compact: false) {
            groups.append(SettingsGroup("currentLyrics", title: "正在播放", entries: [current]))
        }
        groups += [
            SettingsGroup("menuBar", title: "菜单栏", entries: menuBarLyrics),
            SettingsGroup("lyricSources", title: "来源", entries: sources),
            SettingsGroup("lyricLookup", title: "查找方式", advanced: true, entries: lookup),
        ]
        return groups
    }

    private var menuBarLyrics: [SettingsEntry] {
        var entries = [
            SettingsEntry("menuBarLyrics", "菜单栏歌词", detail: "在屏幕顶部的菜单栏显示正在唱的那一句", keywords: "状态栏歌词 状态栏 顶栏 menu bar 桌面") {
                SettingsSwitch(isOn: Binding { model.showsMenuBarLyrics } set: { model.showsMenuBarLyrics = $0 })
            },
        ]
        if model.showsMenuBarLyrics {
            entries += [
                toggle("menuBarPerSyllable", "逐字点亮", "随演唱一个字一个字亮起，长句跟着滚动；关闭后只显示文字，最省电", \.menuBarLyrics.perSyllable, keywords: "状态栏 菜单栏 逐字 卡拉ok 动画 省电 性能"),
                SettingsEntry("menuBarWidth", "最大宽度", detail: settings.menuBarLyrics.perSyllable ? "更长的歌词随演唱滚动；菜单栏放不下时，系统会隐藏它" : "更长的歌词以“…”省略；菜单栏放不下时，系统会隐藏它", keywords: "状态栏 菜单栏 宽度 长度 刘海") {
                    SettingsSlider(value: bind(\.menuBarLyrics.maxWidth), range: 160...600, step: 10) { "\(Int($0)) pt" }
                },
            ]
        }
        return entries
    }

    private var preferTrackPlatform: SettingsEntry {
        toggle("preferTrackPlatform", "优先当前平台", "先用歌曲所在平台的歌词，它只有逐行歌词时再按平台顺序找逐字的；关闭后完全按平台顺序", \.lyricPreferTrackPlatform, keywords: "歌词来源 跟随歌曲来源 qq 酷狗 网易云")
    }

    private func currentLyrics(compact: Bool) -> SettingsEntry? {
        guard let track = model.player.current else { return nil }
        let player = model.player
        let detail: String = if let origin = player.lyricsOrigin, let format = player.lyrics?.format {
            "来自\(origin.displayName) · \(Self.formatName(format.rawValue))"
        } else {
            "没有找到歌词"
        }
        return SettingsEntry("currentLyrics", compact ? detail : "《\(track.title)》", detail: compact ? nil : detail, keywords: "当前歌词 重新获取") {
            SettingsButton(title: "重新查找", systemName: "arrow.clockwise") { player.reloadLyrics() }
        }
    }

    private var account: [SettingsGroup] {
        let sources = model.accountSources
        var groups = sources.map { source -> SettingsGroup in
            let id = source.id
            let name = source.displayName
            var entries = [
                SettingsEntry("account.\(id.key)", "\(name)账号", keywords: "登录 退出 头像 个人主页 添加账号 \(name)", layout: .custom) { AccountCard(source: id) },
            ]
            entries += model.accounts.keptAccounts(of: id).map { kept in
                SettingsEntry("account.\(id.key).\(kept.userID)", kept.nickname, keywords: "切换账号 \(name) \(kept.detail ?? "")", layout: .custom) { KeptAccountRow(source: id, account: kept) }
            }
            let footer = source.account.supportsMultipleAccounts ? "添加的账号会留在这里，随时切换；切换不会退出其他账号。" : nil
            return SettingsGroup("account.\(id.key)", title: sources.count > 1 ? name : nil, footer: footer, entries: entries)
        }
        if model.registry.sources.contains(where: { $0.supports((any ScrobblingSource).self) }) {
            groups.append(SettingsGroup("sync", title: "同步", entries: [
                toggle("scrobble", "听歌打卡", "听完的歌计入所在平台的听歌排行或播放次数", \.scrobble.enabled, keywords: "听歌排行 播放次数 记录 上报"),
            ]))
        }
        return groups
    }

    private func qualityGroups(_ source: any MusicSource) -> [SettingsGroup] {
        let tiers = source.tiers
        guard Self.hasQualityChoice(source) else { return [] }
        let key = source.id.key
        let following = source.tier(for: settings.preferredQuality)
        let selection = Binding { store.settings.sourceQualities[key] ?? "" } set: { store.settings.sourceQualities[key] = $0.isEmpty ? nil : $0 }
        let options = [("", "跟随全局（\(following.name)）")] + tiers.map { ($0.id, $0.name) }
        return [SettingsGroup("source.\(key).quality", title: "音质", entries: [
            SettingsEntry("source.\(key).quality", "音质", detail: "跟随全局时，按 设置 › 播放 › 音质 选这里对应的一档；实际音质取决于歌曲版本与会员权限", keywords: "\(source.displayName) 无损 hi-res 高品质 码率 杜比") {
                SettingsMenu(selection: selection, options: options)
            },
        ])]
    }

    private func sourceGroups(_ source: any ConfigurableSource) -> [SettingsGroup] {
        let id = source.id
        return source.settingsSections.map { section in
            SettingsGroup("source.\(id.key).\(section.id)", title: section.title, footer: section.footer, advanced: section.advanced, entries: section.settings.map { sourceEntry($0, of: id) })
        }
    }

    static func hasQualityChoice(_ source: any MusicSource) -> Bool {
        source.offersQualityChoice && source.tiers.count > 1
    }

    private var localGroups: [SettingsGroup] {
        let status = model.localStatus
        var entries = [
            SettingsEntry("local.summary", "本地音乐", keywords: "文件夹 扫描 添加 曲库 本地 音乐", layout: .custom) { LocalLibrarySummary() },
        ]
        entries += status.folders.map { folder in
            SettingsEntry("local.folder.\(folder.id)", folder.url.lastPathComponent, detail: folder.path, keywords: "文件夹 \(folder.path)", layout: .custom) { LocalFolderRow(folder: folder) }
        }
        var groups = [SettingsGroup("local.folders", title: "文件夹", footer: "文件夹里的歌有变化时自动更新；移动硬盘拔下后歌曲仍会保留，接上即可播放。", entries: entries)]
        let missing = status.folders.reduce(0) { $0 + $1.missingCount }
        if missing > 0 {
            groups.append(SettingsGroup("local.missing", title: "找不到的歌", entries: [
                SettingsEntry("local.purge", "清除找不到的歌", detail: "\(missing) 首歌的文件已不在原处", keywords: "缺失 清理 删除") { PurgeMissingButton(count: missing) },
            ]))
        }
        return groups
    }

    private func sourceEntry(_ setting: SourceSetting, of id: SourceID, name: String? = nil) -> SettingsEntry {
        let entryID = "source.\(id.key).\(setting.key)"
        let keywords = "\(name ?? model.displayName(of: id)) \(setting.keywords)"
        return SettingsEntry(entryID, setting.title, detail: setting.detail, keywords: keywords, advanced: setting.advanced) {
            switch setting.control {
            case .toggle:
                SettingsSwitch(isOn: Binding { store.settings.sourceSettings(id).bool(setting) } set: { setSource(id, setting, .bool($0)) })
            case .text(let placeholder, _, let secure):
                SettingsTextField(text: Binding { store.settings.sourceSettings(id).string(setting) } set: { setSource(id, setting, .string($0)) }, placeholder: placeholder, secure: secure)
            case .choice(let choices, _):
                SettingsMenu(selection: Binding { store.settings.sourceSettings(id).string(setting) } set: { setSource(id, setting, .string($0)) }, options: choices.map { ($0.value, $0.title) })
            }
        }
    }

    private func setSource(_ id: SourceID, _ setting: SourceSetting, _ value: SourceSettingValues.Value) {
        var values = store.settings.sourceSettings(id)
        values.set(setting, to: value)
        store.settings.setSourceSettings(values, for: id)
    }

    private var storage: [SettingsGroup] {
        let offsets = model.player.lyricOffsets
        return [
            SettingsGroup("songCache", title: "音乐缓存", footer: "只保存听过 20 秒以上的歌，用的是播放时已经下载的文件，不额外消耗流量。空间不够时，先删除最久没听的歌。", entries: [
                toggle("songCacheEnabled", "缓存听过的歌", "再听时直接从本机播放，不用等待加载，也不耗流量", \.cache.enabled, keywords: "音乐缓存 歌曲缓存 离线 边听边存 流量"),
                SettingsEntry("songCacheUsage", "已用空间", keywords: "音乐缓存 歌曲缓存 查看 管理 清理 清除 删除", layout: .block) {
                    SongCacheUsage()
                },
                SettingsEntry("songCacheLimit", "空间上限", detail: "超出后自动删除最久没听的歌", keywords: "音乐缓存 大小 容量 限制") {
                    SettingsMenu(selection: bind(\.cache.sizeLimitGB), options: Self.songCacheLimits(including: settings.cache.sizeLimitGB))
                },
            ]),
            SettingsGroup("caches", title: "其他缓存", footer: "清除缓存不会影响账号和设置，需要时会重新下载。", entries: [
                SettingsEntry("lyricsCache", "歌词缓存", detail: "找到的歌词保存 30 天，再听时立即显示", keywords: "清理 清除 空间") {
                    CacheControl { await model.lyricsCache?.size() ?? 0 } clear: { await model.clearLyricsCache() }
                },
                SettingsEntry("imageCache", "图片缓存", detail: "看过的封面和头像", keywords: "封面 清理 清除 空间") {
                    CacheControl { Int64(ImageStore.shared.diskUsage) } clear: { ImageStore.shared.clearDiskCache() }
                },
                SettingsEntry("cacheFolder", "缓存文件夹", detail: "音乐、歌词和图片缓存都保存在这里", keywords: "目录 caches 打开") {
                    SettingsButton(title: "在访达中显示", systemName: "folder") {
                        let url = Self.cacheFolder
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                },
            ]),
            SettingsGroup("data", title: "数据", advanced: true, entries: [
                SettingsEntry("lyricOffsets", "歌词时间调整", detail: "为每首歌记住的歌词提前 / 延后（含校准结果）", keywords: "偏移 校准 offset") {
                    ForgetControl(unit: "首") { offsets.count } forget: {
                        offsets.removeAll()
                        model.player.setLyricOffset(0)
                    }
                },
                SettingsEntry("dataFolder", "数据文件夹", detail: "账号、歌词偏移和播放队列保存在这里", keywords: "目录 application support") {
                    SettingsButton(title: "在访达中显示", systemName: "folder") {
                        let url = DataDirectory.defaultURL
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                },
            ]),
        ]
    }

    /// The plugins page: every plugin read (on or off), the files that did not load, installing,
    /// then the settings of lyrics-only plugins (a source plugin's are on its own page under music
    /// platforms).
    private var pluginsPage: [SettingsGroup] {
        let manager = model.plugins
        var installed = manager.plugins.map { plugin in
            let manifest = plugin.manifest
            return SettingsEntry("plugin.\(manifest.id)", manifest.name, detail: manifest.description, keywords: "插件 \(manifest.id) \(manifest.author ?? "") 开关 关闭 移除 卸载 更新", layout: .custom) {
                PluginRow(plugin: plugin)
            }
        }
        if installed.isEmpty {
            installed = [SettingsEntry("plugin.none", "还没有插件", detail: "从文件或网址安装，或者把 .js 文件放进插件文件夹后重新加载", keywords: "插件") { EmptyView() }]
        }
        var groups = [SettingsGroup("plugins", title: "插件", footer: "关掉的插件不会加载；播放器自带的插件可以关掉，不能移除。", entries: installed)]
        if !manager.failures.isEmpty {
            groups.append(SettingsGroup("pluginFailures", title: "没能加载", entries: manager.failures.map { failure in
                SettingsEntry("pluginFailure.\(failure.file.path)", failure.file.lastPathComponent, detail: failure.message, keywords: "插件 错误 失败", layout: .custom) {
                    PluginFailureRow(failure: failure)
                }
            }))
        }
        groups.append(SettingsGroup("pluginInstall", title: "安装", footer: "插件由第三方编写，播放器只让它访问它声明的网站。只安装来源可信的插件。", entries: [
            SettingsEntry("pluginFromFile", "从文件安装", detail: "选择一个 .js 插件文件", keywords: "插件 添加 导入 js 文件") { PluginFileInstaller() },
            SettingsEntry("pluginFromAddress", "从网址安装", detail: "插件文件的 http(s) 地址；之后可以从这里更新", keywords: "插件 添加 下载 链接 url 网址", layout: .block) { PluginAddressInstaller() },
            SettingsEntry("pluginFolder", "插件文件夹", detail: "放进这里的 .js 文件在重新加载后生效", keywords: "插件 目录 打开") {
                HStack(spacing: 8) {
                    SettingsButton(title: "重新加载", systemName: "arrow.clockwise") { model.reloadPlugins() }
                    SettingsButton(title: "在访达中显示", systemName: "folder") { model.revealPluginFolder() }
                }
            },
        ]))
        for plugin in manager.enabledPlugins where !plugin.isSource {
            let id = plugin.settingsID
            groups += plugin.settingsSections.map { section in
                SettingsGroup("plugin.\(plugin.manifest.id).\(section.id)", title: [plugin.manifest.name, section.title].compactMap { $0 }.joined(separator: " · "), footer: section.footer,
                              advanced: section.advanced, entries: section.settings.map { sourceEntry($0, of: id, name: plugin.manifest.name) })
            }
        }
        groups.append(pluginDeveloperGroup)
        return groups
    }

    private var pluginDeveloperGroup: SettingsGroup {
        let store = store
        let folders = store.settings.plugins.developmentFolders
        var entries = [
            SettingsEntry("pluginDevelopment", "开发中的插件", detail: "直接从文件夹或 .js 文件加载，不用安装；改了文件后点上面的“重新加载”", keywords: "插件 开发 开发者 调试 文件夹 目录 本地 加载") {
                SettingsButton(title: "添加…", systemName: "plus") { Self.chooseDevelopmentPlugins(store) }
            },
        ]
        entries += folders.map { path in
            let url = URL(fileURLWithPath: path)
            return SettingsEntry("pluginDevelopment.\(path)", url.lastPathComponent, detail: (path as NSString).abbreviatingWithTildeInPath, keywords: "插件 开发 \(path)") {
                HStack(spacing: 8) {
                    SettingsButton(title: "在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    SettingsButton(title: "移除", systemName: "minus") { store.settings.plugins.developmentFolders.removeAll { $0 == path } }
                }
            }
        }
        let inspectable = Binding { store.settings.plugins.inspectable } set: { store.settings.plugins.inspectable = $0 }
        let logsCalls = Binding { store.settings.plugins.logsCalls } set: { store.settings.plugins.logsCalls = $0 }
        entries += [
            SettingsEntry("pluginInspect", "允许调试插件", detail: "在 Safari 的“开发”菜单里列出插件，可以下断点、看日志", keywords: "插件 web inspector 开发者 console 断点") {
                SettingsSwitch(isOn: inspectable)
            },
            SettingsEntry("pluginLogCalls", "记录插件调用", detail: "每次调用的参数、耗时和结果写进系统日志（“控制台”里搜索 plugin）；从终端启动时也打印在终端里", keywords: "插件 日志 调用 开发者 调试 log 控制台 终端") {
                SettingsSwitch(isOn: logsCalls)
            },
        ]
        return SettingsGroup("pluginDeveloper", title: "开发者", footer: "开发中的插件优先于已安装和自带的同 id 插件。", advanced: true, entries: entries)
    }

    private static func chooseDevelopmentPlugins(_ store: SettingsStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.javaScript]
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择插件所在的文件夹，或单个 .js 插件文件"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.path).filter { !store.settings.plugins.developmentFolders.contains($0) }
        store.settings.plugins.developmentFolders += added
    }

    private var about: [SettingsGroup] {
        [
            SettingsGroup("aboutHeader", entries: [
                SettingsEntry("about", "Starry Player", keywords: "版本 关于 version", layout: .custom) { AboutHeader() },
            ]),
            SettingsGroup("reset", title: "重置", entries: [
                SettingsEntry("resetAll", "恢复默认设置", detail: "所有设置回到初始状态，不影响账号、播放队列和歌词时间调整", keywords: "重置 reset") {
                    ResetSettingsButton()
                },
            ]),
        ]
    }

    /// A binding to one setting. Reads go through the store, so the control follows changes
    /// made elsewhere (the Now Playing popover, a reset).
    func bind<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        let store = store
        return Binding { store.settings[keyPath: keyPath] } set: { store.settings[keyPath: keyPath] = $0 }
    }

    private func toggle(_ id: String, _ title: String, _ detail: String?, _ keyPath: WritableKeyPath<AppSettings, Bool>, keywords: String = "", advanced: Bool = false) -> SettingsEntry {
        SettingsEntry(id, title, detail: detail, keywords: keywords, advanced: advanced) { SettingsSwitch(isOn: bind(keyPath)) }
    }

    private func menu<T: Hashable>(_ id: String, _ title: String, _ detail: String?, _ keyPath: WritableKeyPath<AppSettings, T>, _ options: [(T, String)], keywords: String = "") -> SettingsEntry {
        SettingsEntry(id, title, detail: detail, keywords: keywords) {
            SettingsMenu(selection: bind(keyPath), options: options)
        }
    }

    private func slider(_ id: String, _ title: String, _ detail: String?, _ keyPath: WritableKeyPath<AppSettings, Double>, _ range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String, keywords: String = "") -> SettingsEntry {
        SettingsEntry(id, title, detail: detail, keywords: keywords) {
            SettingsSlider(value: bind(keyPath), range: range, step: step, format: format)
        }
    }

    private var lyricSizeBinding: Binding<Double> {
        let store = store
        return Binding { store.settings.lyrics.windowedScale } set: { value in
            let old = store.settings.lyrics.windowedScale
            var lyrics = store.settings.lyrics
            lyrics.windowedScale = value
            if old > 0 { lyrics.fullscreenScale = min(max(lyrics.fullscreenScale * value / old, 0.5), 3) }
            store.settings.lyrics = lyrics
        }
    }

    private var outputBinding: Binding<String> {
        let store = store
        let devices = model.outputDevices
        return Binding { store.settings.outputDevice?.uid ?? "" } set: { uid in
            if uid.isEmpty {
                store.settings.outputDevice = nil
            } else if let device = devices.first(where: { $0.uid == uid }) {
                store.settings.outputDevice = .init(uid: device.uid, name: device.name)
            }
        }
    }

    private var outputOptions: [(String, String)] {
        var options: [(String, String)] = [("", "跟随系统")]
        options += model.outputDevices.map { ($0.uid, $0.name) }
        if let saved = settings.outputDevice, !model.outputDevices.contains(where: { $0.uid == saved.uid }) {
            options.append((saved.uid, "\(saved.name)（未连接）"))
        }
        return options
    }

    private var outputDetail: String {
        if let saved = settings.outputDevice, !model.outputDevices.contains(where: { $0.uid == saved.uid }) {
            return "\(saved.name) 未连接，暂时使用系统输出"
        }
        guard settings.outputDevice == nil else { return "只从这个设备播放，不随系统设置切换" }
        return model.systemOutput.map { "现在是 \($0.name)，随系统设置一起切换" } ?? "随系统设置一起切换"
    }

    private var themeColorDetail: String {
        switch settings.themeColorMode {
        case .cover: "随正在播放的封面变换颜色"
        case .default: "默认的珊瑚色"
        case .custom: "自定义颜色"
        }
    }

    private var sidebarModeDetail: String {
        switch settings.sidebarMode {
        case .docked: "固定在窗口左侧，⌘S 收成图标栏"
        case .floating: "悬浮在页面旁的面板，⌘S 切换为自动隐藏"
        case .autoHide: "指针移到窗口左边缘时滑出，离开后收起"
        }
    }

    private var backgroundDetail: String {
        switch settings.background.style {
        case .artwork: "封面色彩缓缓流动"
        case .blur: "模糊的封面，安静不打扰"
        case .gradient: "取封面颜色的渐变"
        }
    }

    private var vocalModelDetail: String {
        let vocalModel = model.vocalModel
        if vocalModel.isSideLoaded {
            let location = model.vocalModelIsBuiltIn ? "内置" : vocalModel.directory?.path ?? ""
            return "音乐分离模型 \(vocalModel.name)（\(location)），分离出干净的伴奏"
        }
        return "未找到音乐分离模型，正在使用系统人声隔离（人声约降低 7 dB）。可把模型文件夹（plist + .mil + weights）放到 \(model.vocalModelFolder.path)"
    }

    private func chooseLyricFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择包含 .ttml 歌词文件的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.localLyricRepository = url.path
        }
    }

    /// Cache size limit choices in GB (0: no limit), with a saved value that is not one of them.
    static func songCacheLimits(including current: Double) -> [(Double, String)] {
        var values: [Double] = [1, 2, 4, 8, 16, 32, 64]
        if current > 0, !values.contains(current) { values = (values + [current]).sorted() }
        return values.map { ($0, "\($0.formatted(.number.precision(.fractionLength(0...1)))) GB") } + [(0, "不限制")]
    }

    static var cacheFolder: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "moe.mrs4s.starry-player", directoryHint: .isDirectory)
    }

    /// What the provider says it gives; a plugin the app does not come with is marked as one.
    private func providerDetail(_ provider: LyricsProviderID) -> String? {
        let detail = model.lyricProviderDetail(provider)
        guard model.isAddedLyricPlugin(provider) else { return detail }
        return detail.map { "插件 · \($0)" } ?? "插件"
    }

    private static func formatName(_ format: String) -> String {
        switch format {
        case "lrc": "逐行歌词"
        case "ttml": "逐音节歌词（TTML）"
        default: "逐字歌词（\(format.uppercased())）"
        }
    }

    static func appearanceName(_ appearance: AppSettings.Appearance) -> String {
        switch appearance {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    static func sidebarModeName(_ mode: AppSettings.SidebarMode) -> String {
        switch mode {
        case .docked: "停靠"
        case .floating: "浮动"
        case .autoHide: "自动隐藏"
        }
    }
}

/// Separation model: pick, reveal, reset or re-scan the side-loaded separation model. The model
/// the app comes with is not revealed: it lives inside the app.
private struct VocalModelButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            SettingsButton(title: "选择文件夹…", systemName: "folder") { chooseFolder() }
            if !model.vocalModelIsBuiltIn {
                SettingsButton(title: "在访达中显示") { revealFolder() }
            }
            if model.settings.settings.vocalModelDirectory != nil {
                SettingsButton(title: "恢复默认") { model.setVocalModelFolder(nil) }
            }
            SettingsButton(title: "重新检测", systemName: "arrow.clockwise") { model.reloadVocalModel() }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择包含 AUSoundIsolation 模型（plist、.mil 与 weights）的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            model.setVocalModelFolder(url)
        }
    }

    private func revealFolder() {
        let folder = model.vocalModel.directory ?? model.vocalModelFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

private struct ResetSettingsButton: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        SettingsButton(title: "恢复默认", systemName: "arrow.counterclockwise", role: .destructive) { confirming = true }
            .confirmationDialog("恢复所有默认设置？", isPresented: $confirming) {
                Button("恢复默认设置", role: .destructive) {
                    withAnimation(Motion.reveal) { model.resetSettings() }
                }
            } message: {
                Text("外观、播放、歌词等所有设置都会回到初始状态。账号、播放队列和歌词时间调整会保留。")
            }
    }
}
