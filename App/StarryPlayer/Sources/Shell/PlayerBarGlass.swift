import SwiftUI

private struct BarGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var barGlass: Bool {
        get { self[BarGlassKey.self] }
        set { self[BarGlassKey.self] = newValue }
    }
}

extension Motion {
    static let glassGlow = Animation.easeInOut(duration: 0.45)
    static let glassMorph = Animation.spring(response: 0.32, dampingFraction: 0.72)
    static let windowFocus = Animation.easeInOut(duration: 0.35)
}

extension ControlActiveState {
    /// Not an inactive window (`.active`: main but not key, e.g. behind its own popover).
    var isFocused: Bool { self != .inactive }
}

extension View {
    /// The system glass (`glassEffect`) in `shape`. Only the glass bar uses it, which exists on
    /// macOS 26+ only, so older systems (without the API) never get here and draw nothing.
    /// Disabled it is the identity glass, so switching it keeps the view's identity.
    @ViewBuilder
    func barGlass(_ enabled: Bool = true, tint: Color? = nil, clear: Bool = false, interactive: Bool = false, in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(enabled ? (clear ? Glass.clear : Glass.regular).tint(tint).interactive(interactive) : .identity, in: shape)
        } else {
            self
        }
    }

    /// A `GlassEffectContainer` around the view when `enabled` (macOS 26+): its glass shapes
    /// render together and flow into each other when they come within `spacing`.
    @ViewBuilder
    func barGlassContainer(_ enabled: Bool, spacing: CGFloat? = nil) -> some View {
        if enabled, #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

extension AnyTransition {
    static var playerBarGlass: AnyTransition {
        .asymmetric(
            insertion: .offset(y: 24)
                .combined(with: .scale(scale: 0.92, anchor: .bottom))
                .combined(with: .modifier(active: BlurModifier(radius: 14), identity: BlurModifier(radius: 0)))
                .combined(with: .opacity)
                .animation(.spring(response: 0.62, dampingFraction: 0.74)),
            removal: .offset(y: 16)
                .combined(with: .modifier(active: BlurModifier(radius: 10), identity: BlurModifier(radius: 0)))
                .combined(with: .opacity)
                .animation(.easeIn(duration: 0.22))
        )
    }
}

private struct BlurModifier: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

/// Use a separate colour layer: the system drops glass tint immediately on focus loss,
/// preventing a smooth inactive-window transition.
struct GlassBarSurface: View {
    var wash: Color?
    var override: TimeInterval?
    @Environment(\.theme) private var theme
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let shape = Capsule(style: .continuous)
        let wash = wash ?? .clear
        let strength = theme.isDark ? 0.14 : 0.09
        Color.clear
            .barGlass(in: shape)
            .overlay {
                shape.fill(LinearGradient(stops: [
                    .init(color: wash.opacity(strength), location: 0),
                    .init(color: wash.opacity(strength * 0.3), location: 0.45),
                    .init(color: wash.opacity(0), location: 0.8),
                ], startPoint: .leading, endPoint: .trailing))
                .opacity(activeState.isFocused ? 1 : 0)
                .animation(Motion.windowFocus, value: activeState.isFocused)
            }
            .overlay {
                GlassProgressSpill(override: override).clipShape(shape)
            }
            .allowsHitTesting(false)
    }
}

/// Accent glass play button with a separate icon layer so glass vibrancy does not override its
/// colour.
struct GlassPlayButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.controlActiveState) private var activeState
    @State private var hovering = false

    static func darkIcon(accent: Color, focused: Bool, darkTheme: Bool) -> Bool {
        focused ? accent.luminance > 0.5 : !darkTheme
    }

    func makeBody(configuration: Configuration) -> some View {
        let focused = activeState.isFocused
        let pressed = configuration.isPressed
        configuration.label
            .foregroundStyle(Self.darkIcon(accent: theme.accent, focused: focused, darkTheme: theme.isDark) ? Color.black.opacity(0.8) : .white)
            .background {
                Circle().fill(theme.accent.opacity(focused ? 0.86 : 0)).barGlass(in: Circle())
            }
            .scaleEffect(pressed ? 1.1 : (hovering ? 1.05 : 1))
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: pressed)
            .animation(Motion.hover, value: hovering)
            .animation(Motion.windowFocus, value: focused)
            .onHover { hovering = $0 }
            .contentShape(Circle())
    }
}

/// A soft pool of the accent colour inside the glass under the progress head, as if the head lit
/// the glass. A leaf view on the 4 Hz clock, like `BarProgress`.
private struct GlassProgressSpill: View {
    var override: TimeInterval?
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let player = model.player
        GeometryReader { geo in
            let edge = PlayerBar.edge(width: geo.size.width, glass: true)
            let head = edge.point(at: edge.length * BarProgress.fraction(time: override ?? player.shellTime, duration: player.duration))
            Circle()
                .fill(RadialGradient(colors: [theme.accent.opacity(theme.isDark ? 0.22 : 0.15), theme.accent.opacity(0)], center: .center, startRadius: 0, endRadius: 80))
                .frame(width: 160, height: 160)
                .scaleEffect(x: 1, y: 0.5)
                .position(x: head.x, y: head.y + 6)
                .opacity(player.isPlaying || override != nil ? 1 : 0.35)
                .blendMode(theme.isDark ? .plusLighter : .normal)
                .animation(Motion.glassGlow, value: player.isPlaying)
        }
    }
}

/// The glass bar's progress line along `edge`: a faint groove and the played part as light —
/// dim where it began, full accent along the way, white-hot for the last stretch before its
/// head — drawn over a blurred copy of itself (the bloom). Dark glass adds the light (plus
/// lighter); light glass lays a coloured glow instead, which reads on a bright surface.
struct GlassProgressLine: View {
    var edge: BarEdge
    var fraction: CGFloat
    var active: Bool
    var glowing: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let dark = theme.isDark
        let width: CGFloat = active ? 5 : 2
        let headX = edge.point(at: edge.length * fraction).x
        let tail = max(headX - 140, 0) / edge.width
        let hotStart = max(headX - 36, 0) / edge.width
        let head = max(headX / edge.width, hotStart)
        let hot = dark ? Color.white : theme.accent
        let light = LinearGradient(stops: [
            .init(color: theme.accent.opacity(0.5), location: 0),
            .init(color: theme.accent, location: tail),
            .init(color: theme.accent, location: hotStart),
            .init(color: hot, location: head),
        ], startPoint: .leading, endPoint: .trailing)
        let line = BarEdgeLine(edge: edge)
        ZStack {
            line.stroke(dark ? Color.white.opacity(active ? 0.16 : 0.1) : Color.black.opacity(active ? 0.1 : 0.07), style: StrokeStyle(lineWidth: width, lineCap: .round))
            line.trim(from: 0, to: fraction)
                .stroke(light, style: StrokeStyle(lineWidth: width + 2, lineCap: .round))
                .blur(radius: active ? 4 : 3)
                .opacity(glowing ? (dark ? 0.65 : 0.5) : 0.2)
                .blendMode(dark ? .plusLighter : .normal)
            line.trim(from: 0, to: fraction)
                .stroke(light, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .opacity(glowing ? 1 : 0.75)
        }
        .animation(Motion.glassGlow, value: glowing)
    }
}

/// The light at the progress head: a small glowing point that grows into a bead under the
/// pointer and, while dragging, shrinks back to a point inside a clear glass lens. It never
/// leaves the view tree (inserted views' geometry starts late in the bar, see `Ticker`).
struct GlassProgressHead: View {
    var active: Bool
    var scrubbing: Bool
    var glowing: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let dark = theme.isDark
        let halo = dark ? Color.white : theme.accent
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [halo.opacity(dark ? 0.34 : 0.28), theme.accent.opacity(dark ? 0.15 : 0.11), theme.accent.opacity(0)], center: .center, startRadius: 0, endRadius: 15))
                .frame(width: 30, height: 30)
                .scaleEffect(active ? 1.35 : 1)
                .opacity(glowing || active ? 1 : 0.3)
                .blendMode(dark ? .plusLighter : .normal)
            GlassLens(shown: scrubbing, size: 20)
            Circle()
                .fill(.white)
                .overlay(Circle().strokeBorder(theme.accent.opacity(dark ? 0 : 0.5), lineWidth: 1))
                .shadow(color: theme.accent.opacity(0.7), radius: active ? 4 : 2)
                .frame(width: 12, height: 12)
                .scaleEffect(scrubbing ? 0.5 : (active ? 1 : 0.4))
                .opacity(glowing || active ? 1 : 0.55)
        }
        .animation(Motion.glassGlow, value: glowing)
        .animation(Motion.glassMorph, value: scrubbing)
        .allowsHitTesting(false)
    }
}

/// A clear glass lens that swells in over a slider's thumb while it is dragged. Kept in the
/// tree and switched between the identity glass and clear glass, so it grows in place.
struct GlassLens: View {
    var shown: Bool
    var size: CGFloat

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .barGlass(shown, clear: true, in: Circle())
            .scaleEffect(shown ? 1 : 0.5)
            .opacity(shown ? 1 : 0)
    }
}
