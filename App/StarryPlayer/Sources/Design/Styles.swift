import SwiftUI

enum ButtonVariant {
    case filled, secondary, tertiary, ghost
}

struct VariantButtonStyle: ButtonStyle {
    var variant: ButtonVariant = .secondary
    var isCircle = false
    var isPill = false
    var isActive = false
    @Environment(\.theme) private var theme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(fill(pressed: configuration.isPressed), in: shape)
            .overlay(shape.stroke(border, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.hover, value: hovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering = $0 }
            .contentShape(shape)
    }

    private var shape: AnyShape {
        if isCircle { return AnyShape(Circle()) }
        if isPill { return AnyShape(Capsule()) }
        return AnyShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
    }

    private func fill(pressed: Bool) -> Color {
        switch variant {
        case .filled: theme.primary.opacity(hovering ? 0.9 : 1)
        case .secondary: theme.primary.opacity(hovering || isActive ? 0.22 : 0.16)
        case .tertiary: theme.primary.opacity(hovering ? 0.12 : 0.08)
        case .ghost: theme.onSurface.opacity(hovering ? 0.08 : (isActive ? 0.06 : 0))
        }
    }

    private var border: Color {
        variant == .ghost || variant == .filled ? .clear : theme.primary.opacity(0.06)
    }
}

struct IconButton: View {
    var systemName: String
    var size: CGFloat = 36
    var iconSize: CGFloat? = nil
    var variant: ButtonVariant = .ghost
    var tint: Color? = nil
    var isActive = false
    var help: String? = nil
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize ?? size * 0.44, weight: .medium))
                .foregroundStyle(variant == .filled ? theme.onPrimary : (tint ?? (isActive ? theme.primary : theme.onSurface.opacity(0.85))))
                .frame(width: size, height: size)
        }
        .buttonStyle(VariantButtonStyle(variant: variant, isCircle: true, isActive: isActive))
        .help(help ?? "")
    }
}

struct PillButton: View {
    var title: String
    var systemName: String? = nil
    var variant: ButtonVariant = .secondary
    var height: CGFloat = 36
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemName {
                    Image(systemName: systemName).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(variant == .filled ? theme.onPrimary : theme.primary)
            .padding(.horizontal, 18)
            .frame(height: height)
        }
        .buttonStyle(VariantButtonStyle(variant: variant, isPill: true))
    }
}

struct Tag: View {
    enum Style { case neutral, amber, red, primary }
    var text: String
    var style: Style = .neutral
    var soft = false
    @Environment(\.theme) private var theme

    private var color: Color {
        switch style {
        case .neutral: theme.onSurfaceVariant
        case .amber: Color(hex: theme.isDark ? "#F5B94E" : "#B7791F")
        case .red: Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A")
        case .primary: theme.primary
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: soft ? 3 : 4, style: .continuous)
        Text(text)
            .font(.system(size: 10, weight: soft ? .semibold : .bold))
            .foregroundStyle(color)
            .padding(.horizontal, soft ? 4 : 5)
            .padding(.vertical, 1.5)
            .background(soft ? color.opacity(0.14) : .clear, in: shape)
            .overlay(shape.strokeBorder(soft ? .clear : color.opacity(0.7), lineWidth: 1))
    }
}

extension View {
    func glassPanel(radius: CGFloat = Radius.card) -> some View {
        modifier(GlassPanel(radius: radius))
    }
}

struct GlassPanel: ViewModifier {
    var radius: CGFloat
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(theme.surfacePanel.opacity(0.6), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(theme.onSurface.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 20, y: 8)
    }
}

struct PageTitle: View {
    var title: String
    var stat: String? = nil
    var statIcon: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(.system(size: 30, weight: .bold)).foregroundStyle(theme.onSurface)
            if let stat {
                HStack(spacing: 4) {
                    if let statIcon { Image(systemName: statIcon).font(.system(size: 12)) }
                    Text(stat).font(.system(size: 14))
                }
                .foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer()
        }
    }
}

struct StateView: View {
    var systemName: String
    var title: String
    var detail: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemName).font(.system(size: 56, weight: .light)).foregroundStyle(theme.onSurfaceVariant.opacity(0.5))
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.onSurface)
            if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(theme.onSurfaceVariant) }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}
