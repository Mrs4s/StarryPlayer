import AppKit
import SwiftUI

/// Measures SwiftUI content without propagating sizing constraints to the window.
final class HostedRowView: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) var measured: CGFloat?
    var onHeight: ((CGFloat) -> Void)?

    init() {
        super.init(frame: .zero)
        host.sizingOptions = []
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    func show(_ view: AnyView, environment: EnvironmentValues) {
        host.rootView = AnyView(
            view
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    self?.report(height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .environment(\.self, environment)
        )
    }

    private func report(_ height: CGFloat) {
        // Detached hosting views can report invalid sizes while the table recycles rows.
        guard window != nil, bounds.width > 0, height > 0 else { return }
        let rounded = height.rounded(.up)
        guard rounded != measured else { return }
        measured = rounded
        // Defer row-height updates to avoid reentering layout during a SwiftUI update.
        Task { @MainActor [weak self] in
            guard let self, measured == rounded else { return }
            onHeight?(rounded)
        }
    }
}
