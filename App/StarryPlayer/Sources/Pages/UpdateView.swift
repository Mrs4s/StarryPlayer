import AppKit
import SwiftUI

/// The window telling of a newer release: what changed, and the disk image for this Mac.
struct UpdateView: View {
    var release: AppRelease
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private static let notesMaxHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppMark(size: 52)
                    .shadow(color: AppMark.night.opacity(0.3), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Starry Player 有新版本了").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.onSurface)
                    Text(versionLine).font(.system(size: 12.5)).foregroundStyle(theme.onSurfaceVariant)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("更新内容").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.onSurfaceVariant)
                    Spacer()
                    Button { NSWorkspace.shared.open(release.page) } label: {
                        Label("在 GitHub 上查看", systemImage: "arrow.up.right").labelStyle(TrailingIconLabel())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accent)
                    .linkPointer()
                }
                notes
                Text("下载完成后打开磁盘映像，把 Starry Player 拖进“应用程序”文件夹替换旧版本。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("跳过这个版本") {
                    model.updates.skip(release)
                    model.closeUpdate()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.onSurfaceVariant)
                Spacer()
                PillButton(title: "以后再说", variant: .tertiary, height: 32) { model.closeUpdate() }
                PillButton(title: "下载更新", systemName: "arrow.down.circle", variant: .filled, height: 32) {
                    NSWorkspace.shared.open(release.download)
                    model.closeUpdate()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 22)
        .frame(width: 460)
        .background(theme.surfaceAlt.ignoresSafeArea())
        .modifier(WindowCancelShortcut { model.closeUpdate() })
    }

    private var versionLine: String {
        guard let current = model.updates.current else { return "\(release.version) 已发布" }
        return "\(release.version) 已发布，你现在用的是 \(current)"
    }

    /// As tall as the notes, up to `notesMaxHeight`; longer notes scroll.
    private var notes: some View {
        let blocks = release.notes.map(ReleaseNotes.blocks) ?? []
        // No notes at all: a mirror gave only the version.
        let placeholder = release.notes == nil ? "暂时连不上 GitHub，没能取到这次的更新说明，可以稍后到发布页查看。" : "这个版本没有写更新说明。"
        return CappedHeight(maxHeight: Self.notesMaxHeight) {
            ReleaseNotesText(blocks: blocks, placeholder: placeholder).hidden()
            ScrollView {
                ReleaseNotesText(blocks: blocks, placeholder: placeholder).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(14)
            .background(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.035), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(theme.onSurface.opacity(0.06), lineWidth: 1))
    }
}

/// As tall as its first subview at the width offered, up to `maxHeight`; every subview is laid
/// out in that space.
private struct CappedHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

private struct ReleaseNotesText: View {
    var blocks: [ReleaseNotes.Block]
    var placeholder: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if blocks.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(ReleaseNotes.inline(text)).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.onSurface)
                        .padding(.top, 2)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(theme.onSurfaceVariant)
                        Text(ReleaseNotes.inline(text)).foregroundStyle(theme.onSurface.opacity(0.85))
                    }
                    .font(.system(size: 12.5))
                case .paragraph(let text):
                    Text(ReleaseNotes.inline(text)).font(.system(size: 12.5)).foregroundStyle(theme.onSurface.opacity(0.85))
                }
            }
        }
        .lineSpacing(2)
        .tint(theme.accent)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.system(size: 9, weight: .semibold))
        }
    }
}

/// Release notes as GitHub writes them, line by line: headings, bullets and paragraphs, with
/// inline Markdown and bare links made clickable (generated notes link pull requests that way).
enum ReleaseNotes {
    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    static func blocks(_ markdown: String) -> [Block] {
        markdown.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || (line.hasPrefix("<!--") && line.hasSuffix("-->")) { return nil }
            if line.count >= 3, line.allSatisfy({ "-*_".contains($0) }) { return nil }
            if line.hasPrefix("#") { return .heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)) }
            if ["* ", "- ", "+ "].contains(where: line.hasPrefix) { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    static func inline(_ text: String) -> AttributedString {
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let plain = String(string.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return string }
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = match.url, let range = Range(match.range, in: plain) else { continue }
            let lower = string.characters.index(string.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
            let upper = string.characters.index(lower, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
            if string[lower..<upper].link == nil { string[lower..<upper].link = url }
        }
        return string
    }
}
