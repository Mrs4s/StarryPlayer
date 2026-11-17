import AppKit
import SwiftUI

/// Where a view sits, for content in another hosting view than the one that needs to know:
/// an anchor preference does not cross from a table's hosted row to the page around it.
@MainActor
final class ViewAnchor {
    fileprivate weak var view: NSView?

    /// The view's frame in the coordinates of `space`'s view (top-left origin), when both are
    /// in the same window.
    func frame(in space: ViewAnchor) -> CGRect? {
        guard let view, let target = space.view, let window = view.window, window === target.window else { return nil }
        return target.convert(view.bounds, from: view)
    }
}

struct ViewAnchorProbe: NSViewRepresentable {
    var anchor: ViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    private final class ProbeView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
