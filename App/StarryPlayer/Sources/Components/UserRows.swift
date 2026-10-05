import MusicSources
import StarryCore
import SwiftUI

struct UserRows: View {
    var users: [UserProfile]
    /// Tells these rows from another list's in the same lazy stack (a user in both the follows
    /// and the followers must not be taken for the other tab's row).
    var list: String
    @State private var shown = false

    var body: some View {
        let rows = users.enumerated().map { (key: "\(list)-\($0.element.id)", index: $0.offset, user: $0.element) }
        ForEach(rows, id: \.key) { _, index, user in
            UserRow(user: user)
                .staggeredReveal(shown, index: index)
                .onAppear { if !shown { shown = true } }
        }
    }
}

struct UserRow: View {
    var user: UserProfile
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button {
            model.showUser(id: user.id, name: user.nickname, avatar: user.avatar, in: user.source)
        } label: {
            HStack(spacing: 14) {
                ArtworkView(artwork: user.avatar, circle: true, pixelSize: 96, neutralPlaceholder: "person.fill")
                    .frame(width: 44, height: 44)
                    .overlay(Circle().strokeBorder(theme.onSurface.opacity(0.07), lineWidth: 1))
                    .scaleEffect(hovering ? 1.06 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(user.nickname)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.onSurface)
                            .lineLimit(1)
                        if user.isVIP { Tag(text: "VIP", style: .red, soft: true) }
                        if let relation { Tag(text: relation, style: .primary, soft: true) }
                    }
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let followers = user.followerCount, followers > 0 {
                    Text("粉丝 \(TimeFormatting.compactCount(followers))")
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .opacity(hovering ? 1 : 0)
                    .offset(x: hovering ? 0 : -4)
            }
            .padding(.horizontal, 12)
            .frame(height: 64)
            .background(theme.onSurface.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.99))
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }

    private var relation: String? {
        switch (user.isFollowed == true, user.followsYou) {
        case (true, true): "互相关注"
        case (true, false): "已关注"
        case (false, true): "关注了你"
        case (false, false): nil
        }
    }

    @ViewBuilder private var detail: some View {
        if let identity = user.identity {
            Label {
                Text(identity).lineLimit(1)
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: theme.isDark ? "#F5B94E" : "#D08A1E"))
            }
            .labelStyle(SealLabelStyle())
            .font(.system(size: 12.5))
            .foregroundStyle(theme.onSurfaceVariant)
        } else {
            Text(user.signature ?? " ")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(1)
        }
    }
}

private struct SealLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 11))
            configuration.title
        }
    }
}

struct UserSkeleton: View {
    var count: Int
    @Environment(\.theme) private var theme
    private static let nameWidths: [CGFloat] = [96, 132, 84, 150, 110, 70, 124, 90]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 14) {
                    Circle()
                        .fill(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.08))
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBar(width: Self.nameWidths[index % Self.nameWidths.count], height: 11)
                        SkeletonBar(width: 180, height: 9)
                    }
                    Spacer()
                    SkeletonBar(width: 52, height: 9)
                }
                .padding(.horizontal, 12)
                .frame(height: 64)
            }
        }
        .padding(.top, 8)
        .shimmer()
    }
}
