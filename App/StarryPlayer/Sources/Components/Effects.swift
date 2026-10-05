import SwiftUI

/// Entrance: the content fades in, rises `distance` pt and grows from `scale` once `shown`
/// turns true, after `delay`. Only offset / scale / opacity change, so it never moves layout.
/// With Reduce Motion on it only fades.
struct Reveal: ViewModifier {
    var shown: Bool
    var delay: Double = 0
    var distance: CGFloat = 10
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : scale)
            .offset(y: shown || reduceMotion ? 0 : distance)
            .animation(Motion.reveal.delay(delay), value: shown)
    }
}

extension View {
    func reveal(_ shown: Bool, delay: Double = 0, distance: CGFloat = 10, scale: CGFloat = 1) -> some View {
        modifier(Reveal(shown: shown, delay: delay, distance: distance, scale: scale))
    }

    func staggeredReveal(_ shown: Bool, index: Int, base: Double = 0, distance: CGFloat = 8) -> some View {
        reveal(shown, delay: base + Double(min(index, Motion.staggerLimit)) * Motion.staggerStep, distance: distance)
    }

    func shimmer() -> some View { modifier(Shimmer()) }
}

struct Shimmer: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isPageActive) private var pageActive
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    let width = geo.size.width
                    LinearGradient(colors: [.clear, theme.onSurface.opacity(theme.isDark ? 0.09 : 0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width * 0.45)
                        .offset(x: -width * 0.45 + phase * width * 1.45)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            // Use finite, cancellable sweeps: `repeatForever` can outlive a removed skeleton
            // and keep hidden pages rendering.
            .task(id: pageActive) {
                guard pageActive else { return }
                while !Task.isCancelled {
                    withAnimation(.linear(duration: 1.4)) { phase = 1 }
                    try? await Task.sleep(for: .seconds(1.4))
                    withTransaction(Transaction(animation: nil)) { phase = 0 }
                    try? await Task.sleep(for: .seconds(0.2))
                }
            }
    }
}

struct SkeletonBar: View {
    var width: CGFloat
    var height: CGFloat = 10
    @Environment(\.theme) private var theme

    var body: some View {
        Capsule().fill(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.08)).frame(width: width, height: height)
    }
}
