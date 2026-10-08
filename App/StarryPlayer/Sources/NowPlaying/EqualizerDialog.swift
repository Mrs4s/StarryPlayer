import AppKit
import AudioProcessing
import StarryCore
import SwiftUI
import UniformTypeIdentifiers

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
    /// The parametric band being edited (its slot).
    @State private var selectedBand: Int?
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
        let equalizer = model.player.equalizer
        let parametric = equalizer.mode == .parametric
        return VStack(alignment: .leading, spacing: 0) {
            header(equalizer)
                .modifier(DialogRise(index: 0, arrived: arrived, reduceMotion: reduceMotion))
            Group {
                if parametric { parametricBody(equalizer) } else { graphicBody(equalizer) }
            }
            .transition(.opacity)
            footer(equalizer)
                .padding(.top, 14)
                .modifier(DialogRise(index: parametric ? 4 : 3, arrived: arrived, reduceMotion: reduceMotion))
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    @ViewBuilder
    private func graphicBody(_ equalizer: EqualizerSettings) -> some View {
        let player = model.player
        presets(equalizer)
            .padding(.top, 20)
            .modifier(DialogRise(index: 1, arrived: arrived, reduceMotion: reduceMotion))
        EqualizerGraph(gains: equalizer.gains, isEnabled: equalizer.isEnabled, tint: tint, spectrumLive: player.isPlaying, spectrum: { [player] in player.spectrumBands() }) { band, gain in
            player.setEqualizerGain(gain, band: band)
        }
        .frame(height: 236)
        .padding(.top, 16)
        .modifier(DialogRise(index: 2, arrived: arrived, reduceMotion: reduceMotion))
    }

    /// The same height as the ten bands' presets and graph: a row of bands, the graph, and the
    /// selected band's values.
    @ViewBuilder
    private func parametricBody(_ equalizer: EqualizerSettings) -> some View {
        let player = model.player
        let selected = selectedBand.flatMap { equalizer.band(slot: $0) }
        ParametricBandStrip(equalizer: equalizer, selection: selected?.slot, tint: tint, select: { selectedBand = $0 }, add: addBand, menu: transferMenu)
            .frame(height: 30)
            .padding(.top, 20)
            .modifier(DialogRise(index: 1, arrived: arrived, reduceMotion: reduceMotion))
        ParametricEqualizerGraph(
            bands: equalizer.bands, isEnabled: equalizer.isEnabled, tint: tint, selection: selected?.slot,
            spectrumLive: player.isPlaying, spectrum: { [player] in player.spectrumBands() },
            onSelect: { selectedBand = $0 },
            onChange: { band in player.updateEqualizerBand(slot: band.slot) { $0 = band } },
            onAdd: { player.addEqualizerBand($0) },
            onRemove: { player.removeEqualizerBand(slot: $0) }
        )
        .frame(height: 236)
        .padding(.top, 12)
        .modifier(DialogRise(index: 2, arrived: arrived, reduceMotion: reduceMotion))
        ParametricBandInspector(band: selected, hasBands: !equalizer.bands.isEmpty, isEnabled: equalizer.isEnabled, tint: tint) { change in
            if let slot = selected?.slot { player.updateEqualizerBand(slot: slot, change) }
        } remove: {
            if let slot = selected?.slot {
                selectedBand = nil
                player.removeEqualizerBand(slot: slot)
            }
        }
        .frame(height: 30)
        .padding(.top, 10)
        .modifier(DialogRise(index: 3, arrived: arrived, reduceMotion: reduceMotion))
    }

    /// A 0 dB peak (Q 1) in the widest gap between the bands, selected.
    private func addBand() {
        let player = model.player
        let edges = ParametricEqualizer.displayRange
        let positions = ([edges.lowerBound, edges.upperBound] + player.equalizer.bands.map(\.frequency)).map { log2(min(max($0, edges.lowerBound), edges.upperBound)) }.sorted()
        var gap = (start: positions[0], width: 0.0)
        for (low, high) in zip(positions, positions.dropFirst()) where high - low > gap.width { gap = (low, high - low) }
        let frequency = ParametricEqualizer.rounded(frequency: pow(2, gap.start + gap.width / 2))
        if let slot = player.addEqualizerBand(ParametricBand(slot: 0, frequency: frequency)) {
            selectedBand = slot
        } else {
            NSSound.beep()
        }
    }

    @PopMenuBuilder
    private func transferMenu() -> [PopMenuItem] {
        let player = model.player
        let equalizer = player.equalizer
        PopMenuItem.button("从文件导入…", systemImage: "doc.badge.plus") {
            EqualizerTransfer.importFile(into: model) { selectedBand = nil }
        }
        PopMenuItem.button("从剪贴板导入", systemImage: "doc.on.clipboard", disabled: NSPasteboard.general.string(forType: .string) == nil) {
            EqualizerTransfer.importClipboard(into: model) { selectedBand = nil }
        }
        PopMenuItem.divider
        PopMenuItem.button("拷贝设置", systemImage: "doc.on.doc", disabled: equalizer.bands.isEmpty) {
            EqualizerTransfer.copy(from: model)
        }
        PopMenuItem.button("导出为文件…", systemImage: "square.and.arrow.up", disabled: equalizer.bands.isEmpty) {
            EqualizerTransfer.exportFile(from: model)
        }
        PopMenuItem.divider
        PopMenuItem.button("用十段曲线替换", systemImage: "slider.vertical.3", disabled: equalizer.gains.allSatisfy { $0 == 0 }) {
            selectedBand = nil
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                player.updateEqualizer { $0.useGraphicCurve() }
            }
        }
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
            EqualizerModePicker(mode: equalizer.mode, tint: tint) { mode in
                selectedBand = nil
                withAnimation(.easeInOut(duration: 0.22)) { model.player.setEqualizerMode(mode) }
            }
            .padding(.trailing, 4)
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
        if equalizer.mode == .parametric { parts.append(equalizer.bands.isEmpty ? "没有频段" : "\(equalizer.bands.count) 个频段") }
        if equalizer.activePreamp != 0 { parts.append("前级 \(Self.decibels(equalizer.activePreamp))") }
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
        let preamp = equalizer.activePreamp
        let parametric = equalizer.mode == .parametric
        return HStack(spacing: 12) {
            Text("前级")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint.opacity(0.7))
            PreampSlider(value: preamp, tint: tint) { value in
                player.updateEqualizer {
                    $0.setPreamp(value)
                    $0.isEnabled = true
                }
            }
            .frame(width: 196)
            Text(Self.decibels(preamp))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint.opacity(preamp == 0 ? 0.5 : 0.9))
                .contentTransition(.numericText(value: preamp))
                .frame(width: 58, alignment: .leading)
            Spacer(minLength: 8)
            FooterChip(title: "自动", systemImage: "wand.and.stars", active: false, tint: tint) {
                player.updateEqualizer {
                    $0.setPreamp(-($0.peakGain * 10).rounded(.up) / 10)
                    $0.isEnabled = true
                }
            }
            .help("把前级设为曲线最高点的负值，提升的频段不会削波")
            FooterChip(title: "防削波", systemImage: equalizer.clipGuard ? "checkmark.shield.fill" : "shield", active: equalizer.clipGuard, tint: tint) {
                player.updateEqualizer { $0.clipGuard.toggle() }
            }
            .help("提升增益时压住峰值，避免破音")
            FooterChip(title: "重置", systemImage: "arrow.counterclockwise", active: false, tint: tint) {
                selectedBand = nil
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    player.updateEqualizer { $0.reset() }
                }
            }
            .disabled(parametric ? equalizer.bands.isEmpty && preamp == 0 : equalizer.isFlat && equalizer.presetID == EqualizerPreset.flat.id)
            .help(parametric ? "删除所有频段，前级归零（十段均衡不受影响）" : "回到平直，前级归零（自定义的曲线会保留）")
        }
        .frame(height: 32)
    }
}

/// 十段 | 参数, with the picked one in a pill that slides across.
private struct EqualizerModePicker: View {
    var mode: EqualizerMode
    var tint: Color
    var onChange: (EqualizerMode) -> Void
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach([(EqualizerMode.graphic, "十段"), (.parametric, "参数")], id: \.0) { value, title in
                let selected = mode == value
                Button { if !selected { onChange(value) } } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Color.black.opacity(0.8) : tint.opacity(0.72))
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background {
                            if selected {
                                Capsule().fill(tint.opacity(0.92))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(NowPlayingPressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(tint.opacity(0.08)))
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: mode)
        .help("十段：预设和滑块；参数：自由添加频段，可导入 AutoEQ")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("均衡器模式")
    }
}

/// The parametric bands by frequency to pick from, a button to add one, and import / export.
private struct ParametricBandStrip: View {
    var equalizer: EqualizerSettings
    var selection: Int?
    var tint: Color
    var select: (Int) -> Void
    var add: () -> Void
    var menu: () -> [PopMenuItem]

    var body: some View {
        let bands = equalizer.bands.sorted { $0.frequency < $1.frequency }
        HStack(spacing: 8) {
            if bands.isEmpty {
                Text("双击曲线添加频段，或导入 AutoEQ、Equalizer APO 的设置")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(bands) { band in
                                ParametricBandChip(band: band, selected: band.slot == selection, enabled: equalizer.isEnabled, tint: tint) { select(band.slot) }
                                    .id(band.slot)
                            }
                        }
                    }
                    .onChange(of: selection) { _, slot in
                        guard let slot else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(slot, anchor: .center) }
                    }
                }
            }
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
            }
            .buttonStyle(NowPlayingCircleButtonStyle(tint: tint, size: 30))
            .disabled(bands.count >= ParametricEqualizer.maxBands)
            .help(bands.count >= ParametricEqualizer.maxBands ? "最多 \(ParametricEqualizer.maxBands) 个频段" : "添加频段")
            PopMenu(items: menu) { open in
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .bold))
                    Text("导入/导出")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(tint.opacity(open ? 1 : 0.8))
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(Capsule().fill(tint.opacity(open ? 0.18 : 0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(NowPlayingPressStyle())
            .fixedSize()
            .help("Equalizer APO 格式（AutoEQ 的 ParametricEQ.txt、Room EQ Wizard 的滤波器设置）")
        }
    }
}

private struct ParametricBandChip: View {
    var band: ParametricBand
    var selected: Bool
    var enabled: Bool
    var tint: Color
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let lit = selected && enabled
        Button(action: action) {
            HStack(spacing: 5) {
                Text("\(band.slot + 1)")
                    .font(.system(size: 9.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(lit ? tint : Color.black.opacity(0.75))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(lit ? Color.black.opacity(0.7) : tint.opacity(band.isOn && enabled ? 0.9 : 0.35)))
                Text(Self.shortFrequency(band.frequency))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(lit ? Color.black.opacity(0.8) : tint.opacity(hovering || selected ? 0.95 : 0.72))
            }
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .frame(height: 30)
            .background(Capsule().fill(selected ? tint.opacity(enabled ? 0.92 : 0.3) : tint.opacity(hovering ? 0.12 : 0.06)))
            .opacity(band.isOn ? 1 : 0.55)
            .contentShape(Capsule())
        }
        .buttonStyle(NowPlayingPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help("\(band.filter.name) \(ParametricEqualizer.frequencyText(band.frequency))\(band.isOn ? "" : "（已停用）")")
        .accessibilityLabel("第 \(band.slot + 1) 段，\(band.filter.name)，\(ParametricEqualizer.frequencyText(band.frequency))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "62.5", "250", "2.2k", "12k".
    static func shortFrequency(_ frequency: Double) -> String {
        if frequency >= 1000 {
            let text = String(format: "%.1f", frequency / 1000)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "k"
        }
        return frequency < 100 && frequency.rounded() != frequency ? String(format: "%.1f", frequency) : String(format: "%.0f", frequency)
    }
}

/// The selected band's type, frequency, gain and Q, to type or scroll, with buttons to turn
/// it off and remove it.
private struct ParametricBandInspector: View {
    var band: ParametricBand?
    /// Whether there is any band to pick (the hint says how otherwise; the row above says how to add one).
    var hasBands: Bool
    var isEnabled: Bool
    var tint: Color
    var change: ((inout ParametricBand) -> Void) -> Void
    var remove: () -> Void

    var body: some View {
        if let band {
            HStack(spacing: 8) {
                Text("\(band.slot + 1)")
                    .font(.system(size: 10.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(band.isOn && isEnabled ? Color.black.opacity(0.78) : tint.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(band.isOn && isEnabled ? tint : tint.opacity(0.16)))
                PopMenu(placement: .above) {
                    for filter in ParametricFilter.allCases {
                        PopMenuItem.option(filter.name, selected: filter == band.filter) { change { $0.filter = filter } }
                    }
                } label: { open in
                    HStack(spacing: 4) {
                        Text(band.filter.name)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(tint.opacity(0.95))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(tint.opacity(open ? 0.18 : 0.08)))
                    .contentShape(Capsule())
                }
                .buttonStyle(NowPlayingPressStyle())
                .fixedSize()
                .help("滤波器类型")
                EqualizerValueField(title: "频率", text: ParametricEqualizer.frequencyText(band.frequency), draft: String(format: "%g", band.frequency), tint: tint, width: 112, parse: ParametricEqualizer.frequency(from:)) { value in
                    change { $0.frequency = value }
                } step: { steps in
                    change { $0.frequency = ParametricEqualizer.rounded(frequency: $0.frequency * pow(2, steps / 24)) }
                }
                if band.filter.hasGain {
                    EqualizerValueField(title: "增益", text: ParametricEqualizer.gainText(band.gain), draft: String(format: "%g", band.gain), tint: tint, width: 100, parse: ParametricEqualizer.gain(from:)) { value in
                        change { $0.gain = (value * 10).rounded() / 10 }
                    } step: { steps in
                        change { $0.gain = (($0.gain + steps * 0.1) * 10).rounded() / 10 }
                    }
                }
                EqualizerValueField(title: "Q", text: ParametricEqualizer.qText(band.q), draft: ParametricEqualizer.qText(band.q), tint: tint, width: 78, parse: ParametricEqualizer.q(from:)) { value in
                    change { $0.q = value }
                } step: { steps in
                    change { $0.q = ($0.q * pow(1.06, steps) * 100).rounded() / 100 }
                }
                Spacer(minLength: 0)
                Button {
                    change { $0.isOn.toggle() }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint.opacity(band.isOn ? 1 : 0.5))
                }
                .buttonStyle(NowPlayingCircleButtonStyle(tint: tint, size: 28, isActive: !band.isOn))
                .help(band.isOn ? "停用此频段" : "启用此频段")
                .accessibilityLabel(band.isOn ? "停用此频段" : "启用此频段")
                Button(action: remove) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                }
                .buttonStyle(NowPlayingCircleButtonStyle(tint: tint, size: 28))
                .help("删除频段（Delete）")
                .accessibilityLabel("删除频段")
            }
            // Another band's fields start over (an edit in progress stays with its band).
            .id(band.slot)
        } else if hasBands {
            Text("点选圆点或上方的频段来编辑 · 双击曲线空白处添加 · 在圆点上滚动调 Q")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tint.opacity(0.45))
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A value to click and type (Return or a click elsewhere applies it, Esc leaves it), or scroll
/// over to step.
private struct EqualizerValueField: View {
    var title: String
    var text: String
    /// What editing starts from.
    var draft: String
    var tint: Color
    var width: CGFloat
    var parse: (String) -> Double?
    var onCommit: (Double) -> Void
    /// Scroll steps, up positive.
    var step: (Double) -> Void
    @State private var editing = false
    @State private var value = ""
    @State private var hovering = false
    @State private var scrollCarry: CGFloat = 0
    @State private var clickMonitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint.opacity(0.55))
            if editing {
                TextField("", text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            } else {
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint.opacity(0.95))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 28, alignment: .leading)
        .background(Capsule().fill(tint.opacity(editing ? 0.16 : (hovering ? 0.12 : 0.07))))
        .overlay(Capsule().strokeBorder(tint.opacity(editing ? 0.4 : 0), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { begin() }
        .onHover { hovering = $0 }
        .onScrollWheel { event in
            if let steps = EqualizerScroll.steps(event, carry: &scrollCarry) { step(steps) }
        }
        .animation(Motion.hover, value: hovering)
        .onChange(of: editing) { _, isEditing in watchClicks(isEditing) }
        .onDisappear { watchClicks(false) }
        .help("点按输入，或在上面滚动调整")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private func begin() {
        guard !editing else { return }
        value = draft
        editing = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        // Untouched, it stays as it was (the draft may be rounded) and the equalizer stays off.
        guard value != draft, let number = parse(value) else { return }
        onCommit(number)
    }

    private func watchClicks(_ on: Bool) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard on else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            if !hovering { commit() }
            return event
        }
    }
}

/// Equalizer APO text in and out of the parametric equalizer: AutoEQ's `ParametricEQ.txt`,
/// Room EQ Wizard's filter settings.
@MainActor
enum EqualizerTransfer {
    static func importFile(into model: AppModel, done: @escaping @MainActor () -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.prompt = "导入"
        panel.message = "选择 Equalizer APO 格式的设置，如 AutoEQ 的 ParametricEQ.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let text = [String.Encoding.utf8, .utf16, .isoLatin1].lazy.compactMap({ try? String(contentsOf: url, encoding: $0) }).first else {
                    model.showToast("读不了这个文件")
                    return
                }
                if apply(text, name: name(of: url), to: model) { done() }
            }
        }
    }

    static func importClipboard(into model: AppModel, done: @escaping @MainActor () -> Void) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        if apply(text, name: "", to: model) { done() }
    }

    static func copy(from model: AppModel) {
        let equalizer = model.player.equalizer
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(EqualizerAPOText.text(preamp: equalizer.parametricPreamp, bands: equalizer.bands), forType: .string)
        model.showToast("已拷贝，可粘贴到 Equalizer APO 的配置里")
    }

    static func exportFile(from model: AppModel) {
        let equalizer = model.player.equalizer
        let text = EqualizerAPOText.text(preamp: equalizer.parametricPreamp, bands: equalizer.bands)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(equalizer.parametricName.isEmpty ? "Starry Player" : equalizer.parametricName) ParametricEQ.txt"
        panel.prompt = "导出"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    model.showToast("已导出")
                } catch {
                    model.showToast("导出失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// Whether anything was imported (it then replaces the parametric bands).
    private static func apply(_ text: String, name: String, to model: AppModel) -> Bool {
        let profile = EqualizerAPOText.parse(text)
        guard !profile.bands.isEmpty else {
            model.showToast("没有找到可用的滤波器（需要 Equalizer APO 格式的 Filter 行）")
            return false
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            model.player.importEqualizer(profile, name: name)
        }
        model.showToast(summary(profile))
        return true
    }

    /// AutoEQ names its files "<headphones> ParametricEQ.txt".
    static func name(of url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix("ParametricEQ") { name.removeLast("ParametricEQ".count) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    static func summary(_ profile: EqualizerAPOText.Profile) -> String {
        var text = "已导入 \(profile.bands.count) 个频段"
        if profile.droppedFilters > 0 { text += "，超出 \(ParametricEqualizer.maxBands) 段的 \(profile.droppedFilters) 个没有导入" }
        if !profile.skippedCommands.isEmpty { text += "，忽略了 \(profile.skippedCommands.joined(separator: "、"))" }
        let range = EqualizerBands.preampRange
        if !range.contains(profile.preamp) {
            text += "；前级 \(EqualizerDialog.decibels(profile.preamp)) 超出范围，按 \(EqualizerDialog.decibels(min(max(profile.preamp, range.lowerBound), range.upperBound))) 处理"
        }
        return text
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
        .fixedSize()
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
