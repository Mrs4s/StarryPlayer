import AppKit
import LyricsCore
import StarryCore
import SwiftUI

/// Floating playback bar. Only leaf views read `shellTime`, keeping clock updates
/// out of the bar's body and suspending them while Now Playing covers it.
struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var scrubValue: Double = 0
    @State private var scrubbing = false
    @State private var showQueue = false
    @State private var showRemaining = false

    static func radius(glass: Bool) -> CGFloat { glass ? Metrics.playerBarHeight / 2 : 18 }

    static func edge(width: CGFloat, glass: Bool) -> BarEdge {
        BarEdge(width: max(width, 1), radius: radius(glass: glass), inset: BarProgress.inset, sweep: glass ? .pi / 3 : .pi / 2)
    }
    private var player: PlayerController { model.player }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius(glass: false), style: .continuous) }

    var body: some View {
        let glass = model.playerBarUsesGlass
        HStack(spacing: 12) {
            trackInfo.frame(maxWidth: .infinity, alignment: .leading)
            BarTransport()
            toolbar.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, glass ? 12 : 10)
        .padding(.trailing, glass ? 14 : 10)
        .frame(height: Metrics.playerBarHeight)
        .background {
            if glass {
                GlassBarSurface(wash: player.accentColor, override: scrubbing ? scrubValue : nil)
            } else {
                classicSurface
            }
        }
        .overlay(alignment: .top) {
            BarProgress(scrubbing: $scrubbing, scrubValue: $scrubValue)
                .offset(y: -BarProgress.above)
        }
        .environment(\.barGlass, glass)
    }

    private var classicSurface: some View {
        let wash = player.accentColor ?? .clear
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(theme.surfacePanel.opacity(theme.isDark ? 0.55 : 0.62))
            shape.fill(LinearGradient(colors: [wash.opacity(theme.isDark ? 0.26 : 0.16), wash.opacity(0)], startPoint: .leading, endPoint: UnitPoint(x: 0.72, y: 0.5)))
            shape.strokeBorder(theme.onSurface.opacity(theme.isDark ? 0.09 : 0.07), lineWidth: 1)
        }
        .background(shape.fill(theme.surfacePanel.opacity(0.4)).shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.13), radius: 22, y: 8))
    }

    @ViewBuilder
    private var trackInfo: some View {
        if let track = player.current {
            let direction = player.switchDirection
            HStack(spacing: 11) {
                BarCover(track: track, isPlaying: player.isPlaying, direction: direction)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // The line's width follows the title (the tag and heart come after it),
                        // so only its height clips.
                        Ticker(value: track.title, trigger: track.id, motion: .rise(direction: direction), clipsSides: false) { title in
                            Text(title)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(theme.onSurface)
                                .lineLimit(1)
                        }
                        if let badge = model.availableTiers(of: track).last(where: { $0.badge != nil })?.badge {
                            Tag(text: badge, style: .amber, soft: true).fixedSize()
                        }
                        if model.canLike(track) {
                            HeartButton(track: track, size: 24)
                        }
                    }
                    PlayerBarSecondLine(track: track, direction: direction)
                        .font(.system(size: 12))
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Button { showRemaining.toggle() } label: {
                PlayerBarClock(override: scrubbing ? scrubValue : nil, showRemaining: showRemaining)
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showRemaining ? "显示总时长" : "显示剩余时间")
            .padding(.trailing, 4)
            BarVolume()
            BarIconButton(systemName: "list.bullet", active: showQueue, help: "播放队列") { showQueue.toggle() }
                .popover(isPresented: $showQueue, arrowEdge: .top) { QueuePopover() }
            BarIconButton(systemName: "chevron.up", help: "打开播放页") { player.showNowPlaying = true }
        }
        .barGlassContainer(model.playerBarUsesGlass, spacing: 4)
    }
}

extension AnyTransition {
    static var playerBar: AnyTransition {
        .asymmetric(
            insertion: .offset(y: 28).combined(with: .scale(scale: 0.96, anchor: .bottom)).combined(with: .opacity).animation(Motion.reveal),
            removal: .offset(y: 20).combined(with: .opacity).animation(.easeIn(duration: 0.2))
        )
    }
}

/// 44 pt cover: a new song's cover springs in from a smaller size (from the side it came
/// from), the cover settles back to 0.88 while paused, and hovering shows the way up to the
/// Now Playing page. Keyframes, not an insertion transition (see `Ticker`).
private struct BarCover: View {
    var track: Track
    var isPlaying: Bool
    var direction: Int
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.barGlass) private var glass
    @State private var hovering = false

    private static let size: CGFloat = 44
    private var radius: CGFloat { glass ? 12 : 8 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    private struct CoverFrame {
        var scale: CGFloat = 1
        var offset: CGFloat = 0
        var opacity: Double = 1
        var blur: CGFloat = 0
    }

    var body: some View {
        Button { model.player.showNowPlaying = true } label: {
            ArtworkView(artwork: track.artwork, radius: radius, pixelSize: 120)
                .frame(width: Self.size, height: Self.size)
                .overlay {
                    shape.fill(.black.opacity(hovering ? 0.38 : 0))
                        .overlay {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .opacity(hovering ? 1 : 0)
                                .offset(y: hovering ? 0 : 4)
                        }
                }
                .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: isPlaying ? 6 : 3, y: isPlaying ? 3 : 1)
                .keyframeAnimator(initialValue: CoverFrame(), trigger: track.id) { content, frame in
                    content.scaleEffect(frame.scale).offset(x: frame.offset).opacity(frame.opacity).blur(radius: frame.blur)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        MoveKeyframe(reduceMotion ? 1 : 0.7)
                        SpringKeyframe(1, duration: 0.6, spring: Spring(response: 0.45, dampingRatio: glass ? 0.6 : 0.7))
                    }
                    KeyframeTrack(\.offset) {
                        MoveKeyframe(reduceMotion ? 0 : (direction < 0 ? -8 : 8))
                        SpringKeyframe(0, duration: 0.5, spring: Spring(response: 0.42, dampingRatio: 0.86))
                    }
                    KeyframeTrack(\.opacity) {
                        MoveKeyframe(0)
                        LinearKeyframe(1, duration: 0.2)
                    }
                    KeyframeTrack(\.blur) {
                        MoveKeyframe(glass ? 8 : 0)
                        CubicKeyframe(0, duration: 0.36)
                    }
                }
                .scaleEffect(isPlaying || hovering || reduceMotion ? 1 : 0.88)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.pause, value: isPlaying)
        .help("打开播放页")
        // Where the Now Playing cover flies from and back to. The shell's hosting view fills
        // the window, so its global space is the window's, as is the page's.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.playerBarCoverFrame = $0 }
    }
}

private struct BarTransport: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.barGlass) private var glass
    @Environment(\.controlActiveState) private var activeState
    /// The spinner shows only when a switch takes a moment, so quick switches do not flash it.
    @State private var showSpinner = false

    var body: some View {
        let player = model.player
        HStack(spacing: 6) {
            // Each side of play has its own glass container (the hover bubbles flow between the
            // two buttons); play stays out of them, or a container's glass would cover its icon,
            // which sits over its glass rather than in it (see `GlassPlayButtonStyle`).
            HStack(spacing: 6) {
                if player.isEndless {
                    BarToggleButton(systemName: "hand.thumbsdown", active: false, help: "不喜欢") { model.trashPersonalFMTrack() }
                } else {
                    BarToggleButton(systemName: "shuffle", active: player.shuffle, help: player.shuffle ? "关闭随机播放" : "随机播放") {
                        player.shuffle.toggle()
                    }
                }
                BarNudgeButton(systemName: "backward.fill", nudge: -1, help: "上一曲") { player.previous() }
            }
            .barGlassContainer(glass, spacing: 4)
            Button { player.togglePlayPause() } label: {
                ZStack {
                    if showSpinner {
                        ProgressView()
                            .controlSize(.small)
                            .environment(\.colorScheme, darkSpinner ? .light : .dark)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .contentTransition(.symbolEffect(.replace.downUp))
                            .offset(x: player.isPlaying ? 0 : 1.5)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                }
                .frame(width: 38, height: 38)
                .background {
                    if !glass { Circle().fill(theme.onSurface) }
                }
            }
            .modifier(PlayButtonChrome(glass: glass))
            .help(player.isPlaying ? "暂停" : "播放")
            .animation(.easeOut(duration: 0.2), value: showSpinner)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: player.isPlaying)
            .task(id: player.isLoading) {
                guard player.isLoading else { showSpinner = false; return }
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { showSpinner = true }
            }
            HStack(spacing: 6) {
                BarNudgeButton(systemName: "forward.fill", nudge: 1, help: "下一曲") { player.next() }
                BarToggleButton(systemName: repeatSymbol, active: player.activeRepeat != .off, help: repeatHelp) {
                    player.cycleRepeat()
                }
            }
            .barGlassContainer(glass, spacing: 4)
        }
    }

    private var darkSpinner: Bool {
        glass ? GlassPlayButtonStyle.darkIcon(accent: theme.accent, focused: activeState.isFocused, darkTheme: theme.isDark) : theme.isDark
    }

    private var repeatSymbol: String {
        let player = model.player
        if player.activeRepeat == .one { return "repeat.1" }
        return player.isEndless ? "infinity" : "repeat"
    }

    private var repeatHelp: String {
        let player = model.player
        if player.isEndless { return player.endlessRepeatsOne ? "无限播放" : "单曲循环" }
        return switch player.repeatMode {
        case .off: "列表循环"
        case .all: "单曲循环"
        case .one: "关闭循环"
        }
    }
}

private struct PlayButtonChrome: ViewModifier {
    var glass: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if glass {
            content.buttonStyle(GlassPlayButtonStyle())
        } else {
            content.foregroundStyle(theme.surface).buttonStyle(BarButtonStyle(hoverFill: false, hoverScale: 1.06))
        }
    }
}

/// The bar's round buttons: a faint disc on hover, a springy squeeze on press. In the glass bar
/// a bubble of interactive system glass forms under the pointer instead, and the glass answers
/// the press itself.
private struct BarButtonStyle: ButtonStyle {
    var hoverFill = true
    var pressScale: CGFloat = 0.86
    var hoverScale: CGFloat = 1
    @Environment(\.theme) private var theme
    @Environment(\.barGlass) private var glass
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .background {
                if !glass { Circle().fill(theme.onSurface.opacity(hoverFill && hovering ? 0.08 : 0)) }
            }
            .modifier(GlassBubble(glass: glass, shown: hoverFill && (hovering || pressed)))
            .scaleEffect(glass ? 1 : (pressed ? pressScale : (hovering ? hoverScale : 1)))
            .animation(.spring(response: 0.26, dampingFraction: 0.6), value: pressed)
            .animation(glass ? Motion.glassMorph : Motion.hover, value: hovering)
            .onHover { hovering = $0 }
            .contentShape(Circle())
    }
}

private struct GlassBubble: ViewModifier {
    var glass: Bool
    var shown: Bool

    func body(content: Content) -> some View {
        if glass {
            content.barGlass(shown, interactive: true, in: Circle())
        } else {
            content
        }
    }
}

private struct BarIconButton: View {
    var systemName: String
    var active = false
    var help: String
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? theme.accent : theme.onSurface.opacity(0.82))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(BarButtonStyle())
        .animation(Motion.hover, value: active)
        .help(help)
    }
}

private struct BarNudgeButton: View {
    var systemName: String
    var nudge: CGFloat
    var help: String
    var action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.onSurface.opacity(0.9))
                .keyframeAnimator(initialValue: CGFloat(0), trigger: taps) { content, x in
                    content.offset(x: x)
                } keyframes: { _ in
                    CubicKeyframe(reduceMotion ? 0 : nudge * 5, duration: 0.09)
                    SpringKeyframe(0, duration: 0.4, spring: .bouncy)
                }
                .frame(width: 34, height: 34)
        }
        .buttonStyle(BarButtonStyle())
        .help(help)
    }
}

private struct BarToggleButton: View {
    var systemName: String
    var active: Bool
    var help: String
    var action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.barGlass) private var glass

    var body: some View {
        let glow = glass && active
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(active ? theme.accent : theme.onSurface.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
                .shadow(color: theme.accent.opacity(glow ? 0.7 : 0), radius: 5)
                .frame(width: 30, height: 30)
                .overlay(alignment: .bottom) {
                    Circle()
                        .fill(theme.accent)
                        .shadow(color: theme.accent.opacity(glow ? 1 : 0), radius: 3)
                        .frame(width: 4, height: 4)
                        .scaleEffect(active ? 1 : 0.1)
                        .opacity(active ? 1 : 0)
                        .offset(y: -1)
                }
        }
        .buttonStyle(BarButtonStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: active)
        .help(help)
    }
}

struct BarProgress: View {
    @Binding var scrubbing: Bool
    @Binding var scrubValue: Double
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.barGlass) private var glass
    @State private var hoverX: CGFloat?

    static let height: CGFloat = 16
    static let above: CGFloat = 6.5
    static let inset: CGFloat = 1.5
    private static let thumb: CGFloat = 11

    static func fraction(time: TimeInterval, duration: TimeInterval) -> CGFloat {
        CGFloat(min(max(time / max(duration, 1), 0), 1))
    }

    var body: some View {
        let player = model.player
        let duration = max(player.duration, 1)
        let active = hoverX != nil || scrubbing
        let radius = PlayerBar.radius(glass: glass)
        GeometryReader { geo in
            let edge = PlayerBar.edge(width: geo.size.width, glass: glass)
            let fraction = Self.fraction(time: scrubbing ? scrubValue : player.shellTime, duration: duration)
            let thumb = edge.point(at: edge.length * fraction)
            ZStack(alignment: .topLeading) {
                Group {
                    if glass {
                        GlassProgressLine(edge: edge, fraction: fraction, active: active, glowing: player.isPlaying || active)
                    } else {
                        let style = StrokeStyle(lineWidth: active ? 5 : 2, lineCap: .round)
                        BarEdgeLine(edge: edge).stroke(theme.onSurface.opacity(active ? 0.16 : 0.1), style: style)
                        BarEdgeLine(edge: edge).trim(from: 0, to: fraction).stroke(theme.accent, style: style)
                    }
                }
                .frame(width: edge.width, height: radius)
                .offset(y: Self.above)
                .allowsHitTesting(false)
                Group {
                    if glass {
                        GlassProgressHead(active: active, scrubbing: scrubbing, glowing: player.isPlaying || active)
                    } else {
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .frame(width: Self.thumb, height: Self.thumb)
                            .scaleEffect(active ? (scrubbing ? 1.15 : 1) : 0.2)
                            .opacity(active ? 1 : 0)
                    }
                }
                .position(x: thumb.x, y: thumb.y + Self.above)
                .allowsHitTesting(false)
                if let x = hoverX ?? (scrubbing ? thumb.x : nil) {
                    let along = edge.distance(toX: x)
                    let time = scrubbing ? scrubValue : Double(along / edge.length) * duration
                    Text(TimeFormatting.clock(time))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(glass ? theme.onSurface : theme.surface)
                        .padding(.horizontal, glass ? 9 : 7)
                        .frame(height: glass ? 24 : 20)
                        .background(glass ? .clear : theme.onSurface.opacity(0.92), in: Capsule())
                        .barGlass(glass, tint: theme.surfacePanel.opacity(0.85), in: Capsule())
                        .fixedSize()
                        .position(x: min(max(x, 24), edge.width - 24), y: edge.point(at: along).y + Self.above - (glass ? 24 : 20))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: edge.width, height: Self.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !scrubbing {
                            scrubbing = true
                            player.isSeeking = true
                        }
                        scrubValue = Double(edge.distance(toX: gesture.location.x) / edge.length) * duration
                    }
                    .onEnded { _ in
                        scrubbing = false
                        player.isSeeking = false
                        player.seek(to: scrubValue)
                    }
            )
        }
        .frame(height: Self.height)
        .animation(glass ? .spring(response: 0.34, dampingFraction: 0.68) : .spring(response: 0.3, dampingFraction: 0.78), value: active)
    }
}

struct BarEdge {
    var width: CGFloat
    var radius: CGFloat
    var inset: CGFloat
    var sweep: CGFloat = .pi / 2

    private var arcRadius: CGFloat { radius - inset }
    private var corner: CGFloat { sweep * arcRadius }
    private var straight: CGFloat { max(width - 2 * radius, 0) }
    var length: CGFloat { 2 * corner + straight }

    func point(at distance: CGFloat) -> CGPoint {
        let a = arcRadius
        if distance < corner {
            let angle = sweep - distance / a
            return CGPoint(x: radius - a * sin(angle), y: radius - a * cos(angle))
        }
        if distance < corner + straight {
            return CGPoint(x: radius + distance - corner, y: inset)
        }
        let angle = min((distance - corner - straight) / a, sweep)
        return CGPoint(x: width - radius + a * sin(angle), y: radius - a * cos(angle))
    }

    /// How far along the line its point at `x` lies (the line never doubles back in x); 0 left
    /// of its start, `length` right of its end.
    func distance(toX x: CGFloat) -> CGFloat {
        let a = arcRadius
        if x < radius {
            let angle = asin(min(max((radius - x) / a, 0), sin(sweep)))
            return (sweep - angle) * a
        }
        if x > width - radius {
            return corner + straight + a * asin(min(max((x - width + radius) / a, 0), sin(sweep)))
        }
        return corner + x - radius
    }
}

struct BarEdgeLine: Shape {
    var edge: BarEdge

    func path(in rect: CGRect) -> Path {
        let r = edge.radius
        let a = edge.radius - edge.inset
        let sweep = Angle(radians: edge.sweep)
        var path = Path()
        path.move(to: edge.point(at: 0))
        path.addArc(center: CGPoint(x: r, y: r), radius: a, startAngle: .degrees(270) - sweep, endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: edge.width - r, y: edge.inset))
        path.addArc(center: CGPoint(x: edge.width - r, y: r), radius: a, startAngle: .degrees(270), endAngle: .degrees(270) + sweep, clockwise: false)
        return path
    }
}

private struct BarVolume: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var expanded = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let player = model.player
        HStack(spacing: 0) {
            // Always there, revealed by its frame growing leftwards from the speaker: the frame
            // and the time label beside it move in one layout animation. Inserted instead, the
            // slider would land in place at once and cover the label while the label slid over.
            BarVolumeSlider(value: player.volume) { player.setVolume($0) }
                .padding(.leading, 6)
                .padding(.trailing, 2)
                .frame(width: expanded ? 72 : 0, alignment: .trailing)
                .clipped()
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
            Button { player.toggleMute() } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: player.volume)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(theme.onSurface.opacity(0.82))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(BarButtonStyle())
            .help(player.isMuted ? "取消静音" : "静音")
        }
        .contentShape(Rectangle())
        .onHover(perform: hoverChanged)
        .onScrollWheel { VolumeWheel.applyScroll($0, to: player) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("音量")
        .accessibilityValue(player.isMuted ? "静音" : "\(Int((player.volume * 100).rounded()))%")
        .onDisappear { hoverTask?.cancel() }
    }

    /// Opens after a short hover so sweeping past does not flash it, closes a little after the
    /// pointer leaves. Animated in the caller's transaction, so the time label beside it
    /// slides over instead of jumping.
    private func hoverChanged(_ inside: Bool) {
        hoverTask?.cancel()
        guard inside != expanded else { return }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(inside ? 90 : 350))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { expanded = inside }
        }
    }
}

private struct BarVolumeSlider: View {
    var value: Double
    var onChange: (Double) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.barGlass) private var glass
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let x = width * min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                if glass {
                    let dark = theme.isDark
                    let fill = LinearGradient(colors: [theme.accent.opacity(0.7), dark ? .white : theme.accent], startPoint: .leading, endPoint: .trailing)
                    Capsule().fill(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)).frame(height: 4)
                    Capsule().fill(fill).frame(width: max(x, 4), height: 6)
                        .blur(radius: 3)
                        .opacity(dark ? 0.55 : 0.35)
                        .blendMode(dark ? .plusLighter : .normal)
                    Capsule().fill(fill).frame(width: max(x, 4), height: 4)
                } else {
                    Capsule().fill(theme.onSurface.opacity(0.14)).frame(height: 4)
                    Capsule().fill(theme.onSurface.opacity(0.78)).frame(width: max(x, 4), height: 4)
                }
                ZStack {
                    Circle()
                        .fill(.white)
                        .shadow(color: glass ? theme.accent.opacity(0.6) : .black.opacity(0.3), radius: glass ? 3 : 2, y: glass ? 0 : 1)
                        .opacity(glass && dragging ? 0 : 1)
                    if glass { GlassLens(shown: dragging, size: 11) }
                }
                .frame(width: 11, height: 11)
                .scaleEffect(dragging ? (glass ? 1.6 : 1.15) : 1)
                .offset(x: x - 5.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        onChange(Double(min(max(gesture.location.x / width, 0), 1)))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(width: 64, height: 30)
        .animation(glass ? Motion.glassMorph : Motion.hover, value: dragging)
    }
}

/// Second line under the title: the active lyric line while playing, otherwise the artists.
/// A new lyric line rises into place; a new song's line moves with its title. A leaf view, so
/// the 4 Hz clock updates re-run only this and not the bar (see `PlaybackClockText`).
struct PlayerBarSecondLine: View {
    var track: Track
    var direction: Int = 0
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var shownTrack: TrackRef?

    private struct Key: Hashable {
        var track: TrackRef
        var line: Int?
    }

    private enum Line: Equatable {
        case lyric(String)
        case artists(Track)
    }

    private var currentLyric: (index: Int, text: String)? {
        let player = model.player
        guard player.isPlaying, let lyrics = player.lyrics, let index = lyrics.activeLineIndex(at: player.shellTime), !lyrics.lines[index].text.isEmpty else { return nil }
        return (index, lyrics.lines[index].text)
    }

    var body: some View {
        let lyric = currentLyric
        let newSong = shownTrack != nil && shownTrack != track.id
        Ticker(value: lyric.map { Line.lyric($0.text) } ?? .artists(track), trigger: Key(track: track.id, line: lyric?.index), motion: .rise(direction: newSong ? direction : 1)) { line in
            // One container, so the ticker survives the switch between lyric and artists (a
            // `Group` would give each its own).
            ZStack(alignment: .leading) {
                switch line {
                case .lyric(let text): Text(text).foregroundStyle(theme.onSurfaceVariant).lineLimit(1)
                case .artists(let track): ArtistLinks(track: track, color: theme.onSurfaceVariant, hoverColor: theme.onSurface)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: track.id, initial: true) { shownTrack = track.id }
    }
}

struct PlayerBarClock: View {
    var override: TimeInterval?
    var showRemaining: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let time = override ?? player.shellTime
        let current = TimeFormatting.clock(time)
        if showRemaining {
            Text("\(current) / -\(TimeFormatting.clock(player.duration - time))")
        } else {
            Text("\(current) / \(TimeFormatting.clock(player.duration))")
        }
    }
}

struct QueuePopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let player = model.player
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("播放队列").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.onSurface)
                Text("\(player.queue.count) 首").font(.system(size: 12)).monospacedDigit().foregroundStyle(theme.onSurfaceVariant)
                Spacer()
                Button("清空") { player.clearQueue() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .disabled(player.queue.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Rectangle().fill(theme.onSurface.opacity(0.07)).frame(height: 1).padding(.horizontal, 12)
            if player.queue.isEmpty {
                Text("队列里没有歌曲")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(player.queue) { track in
                                QueueRow(track: track)
                            }
                        }
                        .padding(8)
                    }
                    .onAppear {
                        if let id = player.current?.id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 320, height: 440)
        .background(theme.surfaceAlt)
        .environment(\.theme, theme)
    }
}

struct QueueRow: View {
    var track: Track
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let player = model.player
        let current = player.current == track
        HStack(spacing: 10) {
            ArtworkView(artwork: track.artwork, radius: 6, pixelSize: 100)
                .frame(width: 36, height: 36)
                .overlay {
                    if current {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.4))
                        PlayingBars(color: .white, animating: player.isPlaying && !reduceMotion)
                            .frame(width: 14, height: 12)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: current ? .semibold : .medium))
                    .foregroundStyle(current ? theme.accent : theme.onSurface)
                    .lineLimit(1)
                Text(track.artistText).font(.system(size: 11.5)).foregroundStyle(theme.onSurfaceVariant).lineLimit(1)
            }
            Spacer(minLength: 8)
            if hovering {
                BarIconButton(systemName: "xmark", help: "移出队列") { player.remove(track) }
                    .scaleEffect(0.85)
            } else {
                Text(TimeFormatting.clock(track.duration)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(theme.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .background(theme.onSurface.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { player.play(track) }
        .animation(Motion.hover, value: hovering)
    }
}
