import AppKit
import QuartzCore
import StarryCore
import SwiftUI

/// A vinyl record with the cover as its label, for the album page to slide out from behind the
/// cover. The grooves and the sheen are drawn once and stay still (as the light on a real
/// record does); only the label turns, on a Core Animation layer (`LabelSpinnerView`), so a
/// spinning record costs the main thread nothing per frame. Pausing stops it where it is.
struct VinylDisc: View {
    var artwork: Artwork?
    var spinning: Bool
    @State private var label: CGImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isPageActive) private var pageActive

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(white: 0.17), Color(white: 0.06)], center: .center, startRadius: d * 0.18, endRadius: d * 0.5))
                ForEach(0..<8, id: \.self) { ring in
                    Circle()
                        .stroke(Color.white.opacity(ring.isMultiple(of: 3) ? 0.06 : 0.03), lineWidth: 0.75)
                        .padding(d * (0.045 + CGFloat(ring) * 0.034))
                }
                ZStack {
                    LinearGradient(colors: PlaceholderArt.colors(for: artwork?.seed ?? "starry"), startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(Circle())
                    LabelSpinner(image: label, spinning: spinning && pageActive && !reduceMotion)
                }
                .frame(width: d * 0.4, height: d * 0.4)
                Circle().fill(Color(white: 0.04)).frame(width: d * 0.035, height: d * 0.035)
                Circle()
                    .fill(AngularGradient(colors: [.clear, .white.opacity(0.10), .clear, .clear, .white.opacity(0.07), .clear, .clear], center: .center, angle: .degrees(-35)))
                    .allowsHitTesting(false)
            }
            .frame(width: d, height: d)
        }
        // The album page's cover size (`AlbumPage.coverPixels`), so the cover, its palette and
        // this label share one download and one decoded bitmap.
        .task(id: artwork?.sized(AlbumPage.coverPixels)) {
            guard let url = artwork?.sized(AlbumPage.coverPixels) else { label = nil; return }
            let image = await ImageStore.shared.load(url, maxPixelSize: AlbumPage.coverPixels)
            label = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }
}

private struct LabelSpinner: NSViewRepresentable {
    var image: CGImage?
    var spinning: Bool

    func makeNSView(context: Context) -> LabelSpinnerView { LabelSpinnerView() }

    func updateNSView(_ view: LabelSpinnerView, context: Context) {
        view.setImage(image)
        view.setSpinning(spinning)
    }
}

final class LabelSpinnerView: NSView {
    private let disc = CALayer()
    private var spinning = false
    private static let spinKey = "spin"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        disc.masksToBounds = true
        disc.contentsGravity = .resizeAspectFill
        layer?.addSublayer(disc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.bounds = bounds
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        disc.contentsScale = window?.backingScaleFactor ?? 2
    }

    func setImage(_ image: CGImage?) {
        guard (disc.contents as! CGImage?) !== image else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        disc.contents = image
        CATransaction.commit()
    }

    func setSpinning(_ on: Bool) {
        if disc.animation(forKey: Self.spinKey) == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 12
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            disc.add(spin, forKey: Self.spinKey)
            pause()
            spinning = false
        }
        guard on != spinning else { return }
        spinning = on
        on ? resume() : pause()
    }

    private func pause() {
        let now = disc.convertTime(CACurrentMediaTime(), from: nil)
        disc.speed = 0
        disc.timeOffset = now
    }

    private func resume() {
        let paused = disc.timeOffset
        disc.speed = 1
        disc.timeOffset = 0
        disc.beginTime = 0
        disc.beginTime = disc.convertTime(CACurrentMediaTime(), from: nil) - paused
    }
}
