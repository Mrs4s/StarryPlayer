import AppKit
import SwiftUI

@MainActor
enum VolumeWheel {
    static func applyScroll(_ event: NSEvent, to player: PlayerController) {
        guard event.momentumPhase.isEmpty else { return }
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard delta != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            player.setVolume(player.volume + delta * 0.005)
        } else {
            player.stepVolume(up: delta > 0)
        }
    }
}

extension View {
    /// Scroll-wheel events while the pointer is over this view (SwiftUI has no such modifier on
    /// macOS 14). The events are consumed, so an enclosing scroll view stays put.
    func onScrollWheel(_ action: @escaping (NSEvent) -> Void) -> some View {
        modifier(ScrollWheelModifier(action: action))
    }
}

private struct ScrollWheelModifier: ViewModifier {
    var action: (NSEvent) -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { inside in inside ? install() : remove() }
            .onDisappear(perform: remove)
    }

    private func install() {
        guard monitor == nil else { return }
        let action = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { action(event) }
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// Avoid per-frame hover updates as rows pass under a stationary pointer.
    func pausesHitTestingWhileScrolling() -> some View {
        modifier(ScrollHitTestPause())
    }
}

private struct ScrollHitTestPause: ViewModifier {
    @State private var activity = ScrollActivity()

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!activity.isScrolling)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { activity.moved(to: $0) }
    }
}

@MainActor @Observable
final class ScrollActivity {
    let settle: TimeInterval
    private(set) var isScrolling = false
    @ObservationIgnored private var offset: CGFloat?
    @ObservationIgnored private var lastMove: TimeInterval = 0

    init(settle: TimeInterval = 0.05) {
        self.settle = settle
    }

    func moved(to newOffset: CGFloat) {
        defer { offset = newOffset }
        guard let offset, offset != newOffset else { return }
        lastMove = ProcessInfo.processInfo.systemUptime
        // Keep hit testing available during drag autoscroll.
        guard !isScrolling, NSEvent.pressedMouseButtons == 0 else { return }
        isScrolling = true
        Task { [weak self] in
            while let self {
                let idle = ProcessInfo.processInfo.systemUptime - lastMove
                guard idle < settle else {
                    isScrolling = false
                    return
                }
                try? await Task.sleep(for: .seconds(settle - idle))
            }
        }
    }
}
