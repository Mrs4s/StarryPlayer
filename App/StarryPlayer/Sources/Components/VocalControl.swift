import AppKit
import AudioProcessing
import StarryCore
import SwiftUI

/// Sing mode on the lyrics page. The round button turns vocal attenuation on and off (filled while
/// on, pulsing while the separation unit is built). While it is on, a vertical vocal slider opens
/// beside it: briefly after turning on, and whenever the pointer is over the button or the
/// slider. Scrolling over either nudges the level.
struct VocalControl: View {
    @Binding var isExpanded: Bool
    var size: CGFloat = 32
    var tint: Color
    @Environment(AppModel.self) private var model
    @State private var hoveringButton = false
    @State private var hoveringPanel = false
    @State private var hoverTask: Task<Void, Never>?

    private var player: PlayerController { model.player }
    private var enabled: Bool { player.vocalAttenuationEnabled }
    private var status: VocalAttenuationStatus { player.vocalStatus }

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "music.mic")
                .font(.system(size: 14, weight: .semibold))
                .symbolEffect(.pulse, isActive: enabled && status.isPreparing)
                .foregroundStyle(enabled ? Color.black.opacity(0.78) : tint)
                .frame(width: size, height: size)
                .background(Circle().fill(enabled ? tint : tint.opacity(hoveringButton ? 0.14 : 0)))
                .opacity(status.unavailable != nil ? 0.5 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("唱歌")
        .accessibilityValue(enabled ? "人声 \(Int(player.vocalLevel.rounded()))%" : "关")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.stepVocalLevel(up: true)
            case .decrement: player.stepVocalLevel(up: false)
            @unknown default: break
            }
        }
        .onHover { hoveringButton = $0; hoverChanged() }
        .onScrollWheel(scrolled)
        .overlay(alignment: .trailing) {
            if isExpanded && enabled {
                panel
                    // The gap to the button stays part of the panel so crossing it keeps it open.
                    .padding(.trailing, 10)
                    .contentShape(Rectangle())
                    .onHover { hoveringPanel = $0; hoverChanged() }
                    .onScrollWheel(scrolled)
                    .fixedSize()
                    .offset(x: -size)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .animation(Motion.popover, value: isExpanded)
        .onAppear { if isExpanded { scheduleAutoClose() } }
        .onChange(of: isExpanded) { _, open in
            if open, !hoveringButton, !hoveringPanel { scheduleAutoClose() }
        }
        .onChange(of: enabled) { _, on in
            if !on { isExpanded = false }
        }
        .onDisappear { hoverTask?.cancel() }
    }

    private var panel: some View {
        VStack(spacing: 8) {
            VocalLevelSlider(level: Binding(get: { player.vocalLevel }, set: { player.setVocalLevel($0) }), tint: tint)
            Text("人声 \(Int(player.vocalLevel.rounded()))%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint.opacity(0.85))
                .frame(width: 64)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var helpText: String {
        if let reason = status.unavailable { return reason.message(spatialMix: player.spatialMixName) }
        guard enabled else { return "唱歌：降低原唱人声" }
        let engine = status.usesMusicModel ? "音乐分离模型 \(status.modelName ?? "")" : "系统人声隔离"
        return status.isPreparing ? "正在准备人声分离…" : "关闭唱歌（\(engine)）"
    }

    private func toggle() {
        player.toggleVocalAttenuation()
    }

    private func scheduleAutoClose() {
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !hoveringButton, !hoveringPanel else { return }
            isExpanded = false
        }
    }

    /// Opens after a short hover so sweeping past the button does not flash the slider; closes a
    /// little later so the pointer can travel from the button to the slider.
    private func hoverChanged() {
        hoverTask?.cancel()
        let wanted = enabled && (hoveringButton || hoveringPanel)
        guard wanted != isExpanded else { return }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(wanted ? 100 : 250))
            guard !Task.isCancelled else { return }
            isExpanded = wanted
        }
    }

    private func scrolled(_ event: NSEvent) {
        guard enabled, event.momentumPhase.isEmpty else { return }
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard delta != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            player.setVocalLevel((player.vocalLevel + delta * 0.5).rounded())
        } else {
            player.stepVocalLevel(up: delta > 0)
        }
    }
}

struct VocalLevelSlider: View {
    @Binding var level: Double
    var tint: Color
    var width: CGFloat = 38
    var height: CGFloat = 150

    private var fraction: Double {
        let range = VocalAttenuationCurve.sliderRange
        return (VocalAttenuationCurve.clamp(level) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack(alignment: .bottom) {
                shape.fill(tint.opacity(0.2))
                Rectangle().fill(tint.opacity(0.92)).frame(height: geo.size.height * fraction)
                Image(systemName: "music.mic")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(fraction > 0.15 ? Color.black.opacity(0.7) : tint)
                    .padding(.bottom, 10)
            }
            .clipShape(shape)
            .contentShape(shape)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let range = VocalAttenuationCurve.sliderRange
                let f = 1 - min(max(drag.location.y / max(geo.size.height, 1), 0), 1)
                level = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
            })
        }
        .frame(width: width, height: height)
    }
}

extension VocalAttenuationStatus.Unavailable {
    /// What the user is told when sing mode cannot be used; `spatialMix` names the playing spatial mix.
    func message(spatialMix: String) -> String {
        switch self {
        case .unsupportedSource: "当前歌曲不支持人声控制。"
        case .spatialMix: "\(spatialMix)由系统渲染，不叠加人声控制。"
        case .lowPowerMode: "在 Mac 上关闭低电量模式即可使用人声控制。"
        case .thermal: "Mac 降温后即可使用人声控制。"
        case .performance: "人声控制当前不可用。"
        }
    }
}
