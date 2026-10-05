import AppKit
import AudioProcessing
import StarryCore
import SwiftUI

struct NowPlayingEqualizerButton: View {
    var tint: Color
    var k: CGFloat
    var isOpen: Bool
    var action: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let equalizer = model.player.equalizer
        let on = equalizer.isEnabled
        Button(action: action) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 13 * k, weight: .semibold))
                .foregroundStyle(tint.opacity(on || isOpen || hovering ? 1 : 0.6))
                .frame(width: NowPlayingLayout.equalizerButtonSize.width * k, height: NowPlayingLayout.equalizerButtonSize.height * k)
                .background(RoundedRectangle(cornerRadius: 7 * k, style: .continuous).fill(tint.opacity(isOpen ? 0.24 : (on ? 0.15 : (hovering ? 0.08 : 0)))))
                .contentShape(Rectangle())
        }
        .buttonStyle(NowPlayingPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: on)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isOpen)
        .help(on ? "均衡器：\(equalizer.presetName)" : "均衡器（已关闭）")
        .accessibilityLabel("均衡器")
        .accessibilityValue(on ? equalizer.presetName : "关")
    }
}

struct EqualizerDialog: View {
    var isPresented: Bool
    /// The button it grows from, in the page's coordinates.
    var anchor: CGRect
    var area: CGRect
    var tint: Color
    var close: () -> Void
    var onDismissed: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var arrived = false
    @Namespace private var presetPill

    static let size = CGSize(width: 640, height: 462)

    var body: some View {
        let card = cardFrame
        ZStack(alignment: .topLeading) {
            Color.black.opacity(shown ? 0.34 : 0)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            content
                .frame(width: card.width, height: card.height, alignment: .top)
                .background { background }
                .opacity(shown ? 1 : 0)
                .animation(shown ? .easeOut(duration: 0.16) : .easeIn(duration: 0.22), value: shown)
                .scaleEffect(shown ? 1 : (reduceMotion ? 0.97 : 0.12), anchor: reduceMotion ? .center : unitAnchor(in: card))
                .offset(x: card.minX, y: card.minY)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .accessibilityLabel("均衡器")
        }
        .onAppear {
            withAnimation(openAnimation) { shown = true }
            arrived = true
        }
        .onChange(of: isPresented) { _, presented in
            if presented {
                withAnimation(openAnimation) { shown = true }
            } else {
                withAnimation(closeAnimation) {
                    shown = false
                } completion: {
                    onDismissed()
                }
            }
        }
    }

    private var openAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.46, dampingFraction: 0.8)
    }

    private var closeAnimation: Animation {
        reduceMotion ? .easeIn(duration: 0.16) : .spring(response: 0.32, dampingFraction: 1)
    }

    private var cardFrame: CGRect {
        let size = Self.size
        return CGRect(x: (area.midX - size.width / 2).rounded(), y: max(area.minY, (area.midY - size.height / 2).rounded()), width: size.width, height: size.height)
    }

    /// The button's centre in the card's unit space (outside 0…1: it is below the card).
    private func unitAnchor(in card: CGRect) -> UnitPoint {
        guard anchor.width > 0 else { return UnitPoint(x: 0.5, y: 1.2) }
        return UnitPoint(x: (anchor.midX - card.minX) / card.width, y: (anchor.midY - card.minY) / card.height)
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return shape.fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .overlay(shape.fill(Color.black.opacity(0.4)))
            .overlay(shape.fill(LinearGradient(colors: [tint.opacity(0.12), tint.opacity(0)], startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 22)
    }

    private var content: some View {
        let player = model.player
        let equalizer = player.equalizer
        return VStack(alignment: .leading, spacing: 0) {
            header(equalizer)
                .modifier(DialogRise(index: 0, arrived: arrived, reduceMotion: reduceMotion))
            presets(equalizer)
                .padding(.top, 20)
                .modifier(DialogRise(index: 1, arrived: arrived, reduceMotion: reduceMotion))
            EqualizerGraph(gains: equalizer.gains, isEnabled: equalizer.isEnabled, tint: tint, spectrumLive: player.isPlaying, spectrum: { [player] in player.spectrumBands() }) { band, gain in
                player.setEqualizerGain(gain, band: band)
            }
            .frame(height: 236)
            .padding(.top, 16)
            .modifier(DialogRise(index: 2, arrived: arrived, reduceMotion: reduceMotion))
            footer(equalizer)
                .padding(.top, 14)
                .modifier(DialogRise(index: 3, arrived: arrived, reduceMotion: reduceMotion))
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    private func header(_ equalizer: EqualizerSettings) -> some View {
        let on = equalizer.isEnabled
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(on ? 0.92 : 0.12))
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(on ? Color.black.opacity(0.78) : tint.opacity(0.8))
                    .symbolEffect(.bounce, value: on)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("均衡器")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(tint)
                Text(subtitle(equalizer))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(unprocessed != nil && on ? Color(hex: "#F5B94E") : tint.opacity(0.55))
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
            Spacer(minLength: 12)
            EqualizerSwitch(isOn: on, tint: tint) {
                model.player.setEqualizerEnabled(!on)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            }
            .buttonStyle(NowPlayingCircleButtonStyle(tint: tint, size: 28))
            .help("关闭（Esc）")
            .padding(.leading, 4)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: on)
    }

    /// Why the playing song is not processed (no tap on it), if it is not.
    private var unprocessed: VocalAttenuationStatus.Unavailable? {
        guard model.player.current != nil else { return nil }
        let reason = model.player.vocalStatus.unavailable
        return reason == .unsupportedSource || reason == .spatialMix ? reason : nil
    }

    private func subtitle(_ equalizer: EqualizerSettings) -> String {
        guard equalizer.isEnabled else { return "已关闭，声音不经处理" }
        if unprocessed == .spatialMix { return "\(model.player.spatialMixName)由系统渲染，均衡器暂不生效" }
        if unprocessed == .unsupportedSource { return "这首歌的音源无法处理，均衡器暂不生效" }
        var parts = [equalizer.presetName]
        if equalizer.preamp != 0 { parts.append("前级 \(Self.decibels(equalizer.preamp))") }
        if !equalizer.clipGuard { parts.append("防削波已关") }
        return parts.joined(separator: " · ")
    }

    static func decibels(_ value: Double) -> String {
        value == 0 ? "0 dB" : String(format: "%+.1f dB", value)
    }

    private func presets(_ equalizer: EqualizerSettings) -> some View {
        let items = EqualizerPreset.all.map { ($0.id, $0.name) } + [(EqualizerPreset.customID, "自定义")]
        let perRow = (items.count + 1) / 2
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(items[row * perRow..<min((row + 1) * perRow, items.count)], id: \.0) { id, name in
                        PresetChip(title: name, selected: equalizer.presetID == id, enabled: equalizer.isEnabled, tint: tint, namespace: presetPill) {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                model.player.selectEqualizerPreset(id)
                            }
                        }
                    }
                }
            }
        }
    }

    private func footer(_ equalizer: EqualizerSettings) -> some View {
        let player = model.player
        return HStack(spacing: 12) {
            Text("前级")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint.opacity(0.7))
            PreampSlider(value: equalizer.preamp, tint: tint) { value in
                player.updateEqualizer {
                    $0.setPreamp(value)
                    $0.isEnabled = true
                }
            }
            .frame(width: 196)
            Text(Self.decibels(equalizer.preamp))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint.opacity(equalizer.preamp == 0 ? 0.5 : 0.9))
                .contentTransition(.numericText(value: equalizer.preamp))
                .frame(width: 58, alignment: .leading)
            Spacer(minLength: 8)
            FooterChip(title: "防削波", systemImage: equalizer.clipGuard ? "checkmark.shield.fill" : "shield", active: equalizer.clipGuard, tint: tint) {
                player.updateEqualizer { $0.clipGuard.toggle() }
            }
            .help("提升增益时压住峰值，避免破音")
            FooterChip(title: "重置", systemImage: "arrow.counterclockwise", active: false, tint: tint) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    player.updateEqualizer { $0.reset() }
                }
            }
            .disabled(equalizer.isFlat && equalizer.presetID == EqualizerPreset.flat.id)
            .help("回到平直，前级归零（自定义的曲线会保留）")
        }
        .frame(height: 32)
    }
}

private struct DialogRise: ViewModifier {
    var index: Int
    var arrived: Bool
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived || reduceMotion ? 0 : 12)
            .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.03 + 0.035 * Double(index)), value: arrived)
    }
}

private struct PresetChip: View {
    var title: String
    var selected: Bool
    var enabled: Bool
    var tint: Color
    var namespace: Namespace.ID
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(selected && enabled ? Color.black.opacity(0.8) : tint.opacity(selected ? 1 : (hovering ? 0.95 : 0.72)))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    if selected {
                        Capsule().fill(tint.opacity(enabled ? 0.92 : 0.3))
                            .matchedGeometryEffect(id: "pill", in: namespace)
                    } else {
                        Capsule().fill(tint.opacity(hovering ? 0.12 : 0.06))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(NowPlayingPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct EqualizerSwitch: View {
    var isOn: Bool
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(SwitchStyle(isOn: isOn, tint: tint))
            .help(isOn ? "关闭均衡器" : "打开均衡器")
            .accessibilityLabel("均衡器")
            .accessibilityValue(isOn ? "开" : "关")
    }

    private struct SwitchStyle: ButtonStyle {
        var isOn: Bool
        var tint: Color

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            Capsule()
                .fill(tint.opacity(isOn ? 0.92 : 0.16))
                .frame(width: 44, height: 26)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Color.black.opacity(0.75) : tint.opacity(0.9))
                        .frame(width: pressed ? 25 : 20, height: 20)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .padding(3)
                }
                .contentShape(Capsule())
                .animation(.spring(response: 0.32, dampingFraction: 0.66), value: isOn)
                .animation(.spring(response: 0.22, dampingFraction: 0.8), value: pressed)
        }
    }
}

private struct FooterChip: View {
    var title: String
    var systemImage: String
    var active: Bool
    var tint: Color
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(tint.opacity(active || hovering ? 0.95 : 0.7))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(tint.opacity(active ? 0.16 : (hovering ? 0.1 : 0.05))))
            .contentShape(Capsule())
        }
        .buttonStyle(NowPlayingPressStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: active)
    }
}

/// The preamp, −12…+12 dB around a centre mark: the fill grows from the centre to the knob.
/// Drag or click to set it (it holds at 0 dB on the way through), double-click for 0 dB, scroll
/// for ±0.5 dB.
private struct PreampSlider: View {
    var value: Double
    var tint: Color
    var onChange: (Double) -> Void
    @State private var hovering = false
    @State private var dragging = false
    @State private var scrollCarry: CGFloat = 0

    var body: some View {
        let range = EqualizerBands.preampRange
        let active = hovering || dragging
        GeometryReader { geo in
            let width = max(geo.size.width - 16, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let knobX = 8 + width * fraction
            let middle = 8 + width / 2
            let track: CGFloat = active ? 8 : 5
            ZStack(alignment: .topLeading) {
                Capsule().fill(tint.opacity(0.14))
                    .frame(width: width, height: track)
                    .position(x: middle, y: geo.size.height / 2)
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: abs(knobX - middle), height: track)
                    .position(x: (knobX + middle) / 2, y: geo.size.height / 2)
                Capsule().fill(tint.opacity(0.4))
                    .frame(width: 2, height: track + 6)
                    .position(x: middle, y: geo.size.height / 2)
                Circle().fill(tint)
                    .frame(width: dragging ? 17 : (hovering ? 15 : 13))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .position(x: knobX, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        var next = range.lowerBound + Double((drag.location.x - 8) / width) * (range.upperBound - range.lowerBound)
                        if abs(next) < 0.4 { next = 0 }
                        onChange(next)
                    }
                    .onEnded { _ in dragging = false }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0) })
        }
        .frame(height: 24)
        .onHover { hovering = $0 }
        .onScrollWheel { event in
            if let steps = EqualizerScroll.steps(event, carry: &scrollCarry) { onChange(value + steps * 0.5) }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: active)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: dragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("前级增益")
        .accessibilityValue(EqualizerDialog.decibels(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(value + 0.5)
            case .decrement: onChange(value - 0.5)
            @unknown default: break
            }
        }
    }
}

/// Scrolling over a band or the preamp: a wheel notch, or about 8 pt of trackpad travel, is one
/// step; momentum after the fingers lift is ignored, like the volume.
enum EqualizerScroll {
    /// Whole steps to apply (up is positive), keeping the remainder in `carry`.
    static func steps(_ event: NSEvent, carry: inout CGFloat) -> Double? {
        guard event.momentumPhase.isEmpty else { return nil }
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        carry += event.hasPreciseScrollingDeltas ? delta / 8 : delta
        let steps = carry.rounded(.towardZero)
        guard steps != 0 else { return nil }
        carry -= steps
        return Double(steps)
    }
}
