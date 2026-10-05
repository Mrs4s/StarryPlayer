import SwiftUI

/// Single-line scrolling text with faded edges; selectable text pauses on hover.
/// Keep the view tree stable when measurements arrive to avoid jumps during transitions.
struct MarqueeText: View {
    var text: String
    var gap: CGFloat = 32
    var fade: CGFloat = 16
    var delay: Double = 3
    var rate: Double = 30
    var selectable = false
    @State private var textWidth: CGFloat = 0
    @State private var hovering = false
    @State private var boxWidth: CGFloat = 0
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String, gap: CGFloat = 32, fade: CGFloat = 16, delay: Double = 3, rate: Double = 30, selectable: Bool = false) {
        self.text = text
        self.gap = gap
        self.fade = fade
        self.delay = delay
        self.rate = rate
        self.selectable = selectable
    }

    private var scrolls: Bool { !reduceMotion && boxWidth > 0 && textWidth > boxWidth.rounded(.up) }
    private var holding: Bool { selectable && hovering }

    var body: some View {
        // The hidden copy sets the height and measures the natural width; the frame takes the
        // proposed width (`minWidth: 0`, otherwise it never gets narrower than the text).
        Text(text).lineLimit(1).fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            .hidden()
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .overlay(alignment: .leading) {
                if reduceMotion {
                    Text(text).lineLimit(1).truncationMode(.tail).selectable(selectable)
                } else {
                    track
                }
            }
            .onChange(of: MarqueeKey(text: text, textWidth: textWidth, boxWidth: boxWidth)) {
                start = .now
            }
            .onHover { inside in
                guard selectable else { return }
                withAnimation(.easeOut(duration: 0.35)) { hovering = inside }
                if !inside { start = .now }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    private var track: some View {
        let scrolls = scrolls
        let span = boxWidth + fade * 2
        let holding = holding
        return TimelineView(.animation(paused: !scrolls || holding)) { context in
            HStack(spacing: gap) {
                Text(text)
                Text(text).opacity(scrolls ? 1 : 0)
            }
            .lineLimit(1)
            .fixedSize()
            .selectable(selectable)
            .offset(x: scrolls && !holding ? -offset(at: context.date) : 0)
        }
        .padding(.leading, fade)
        .frame(width: span, alignment: .leading)
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: fade / max(span, 1)),
                .init(color: .black, location: 1 - fade / max(span, 1)),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .padding(.horizontal, -fade)
    }

    private func offset(at date: Date) -> CGFloat {
        let travel = textWidth + gap
        let duration = delay + travel / rate
        let u = max(date.timeIntervalSince(start), 0).truncatingRemainder(dividingBy: duration) / duration
        let p = UnitCurve.easeInOut.value(at: u)
        let hold = delay / duration
        return p <= hold ? 0 : (p - hold) / (1 - hold) * travel
    }
}

private struct MarqueeKey: Equatable {
    var text: String
    var textWidth: CGFloat
    var boxWidth: CGFloat
}

private extension View {
    @ViewBuilder func selectable(_ on: Bool) -> some View {
        if on { textSelection(.enabled) } else { self }
    }
}
