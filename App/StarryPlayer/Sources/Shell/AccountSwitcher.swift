import AppKit
import MusicSources
import StarryCore
import SwiftUI

/// Who the app browses as: a source and an account of it — the one signed in, one kept for
/// switching, or none. The header's account chip and its switcher name accounts, not sources: the
/// source is a badge on the avatar and a small grey caption under the name.
struct AccountIdentity: Identifiable, Hashable {
    enum Kind: Hashable {
        case signedIn
        case kept
        case signingIn
        case signedOut
        case expired
        case noAccounts
    }

    var source: SourceID
    var sourceName: String
    var symbol: String
    var kind: Kind
    var userID: String?
    var nickname: String?
    var avatar: Artwork?
    var isVIP = false
    /// The server the account is on, for a source whose accounts can be on different ones.
    var detail: String?

    var id: String { "\(source.key)|\(userID ?? "")" }

    var hasAccount: Bool { kind == .signedIn || kind == .kept }

    /// The name line: the account's name. With no account the source is all there is to name, so
    /// its name stands there (and how it stands goes under it): three rows of `未登录` could only be
    /// told apart by their small print.
    var title: String {
        switch kind {
        case .signedIn, .kept: nickname ?? sourceName
        case .signingIn: "登录中…"
        case .signedOut, .expired, .noAccounts: sourceName
        }
    }

    /// The small line under it: the source (and the server), or how a source with no one signed
    /// in stands. None for a source without accounts.
    var caption: String? {
        switch kind {
        case .signedIn, .kept, .signingIn: [sourceName, detail].compactMap { $0 }.joined(separator: " · ")
        case .signedOut: "未登录"
        case .expired: "登录已过期"
        case .noAccounts: nil
        }
    }
}

struct IdentityGroup: Identifiable, Equatable {
    var source: SourceID
    var identities: [AccountIdentity]
    var id: String { source.key }
}

extension AppModel {
    func sourceSymbol(of id: SourceID) -> String {
        (registry.source(for: id) as? any ConfigurableSource)?.settingsSymbol ?? "music.note"
    }

    func identity(of id: SourceID) -> AccountIdentity {
        var identity = AccountIdentity(source: id, sourceName: displayName(of: id), symbol: sourceSymbol(of: id), kind: .noAccounts)
        guard accountSource(id) != nil else { return identity }
        switch accounts.state(of: id) {
        case .loggedIn(let profile):
            identity.kind = .signedIn
            identity.userID = profile.userID
            identity.nickname = profile.nickname
            identity.avatar = profile.avatar
            identity.isVIP = profile.isVIP
            identity.detail = profile.detail
        case .loggingIn:
            identity.kind = .signingIn
            identity.userID = accounts.currentUser(of: id)
        case .anonymous:
            identity.kind = .signedOut
        case .expired:
            identity.kind = .expired
        }
        return identity
    }

    var identityGroups: [IdentityGroup] {
        registry.sources.map { source in
            let current = identity(of: source.id)
            let kept = accounts.keptAccounts(of: source.id).map { account in
                AccountIdentity(source: source.id, sourceName: current.sourceName, symbol: current.symbol, kind: .kept, userID: account.userID,
                                nickname: account.nickname, avatar: account.avatar, isVIP: account.isVIP, detail: account.detail)
            }
            return IdentityGroup(source: source.id, identities: [current] + kept)
        }
    }

    var browsingIdentity: AccountIdentity {
        if let pending = pendingIdentity, pending.source == browsingSourceID { return pending }
        return identity(of: browsingSourceID)
    }

    func isSwitching(_ identity: AccountIdentity) -> Bool {
        accounts.switching.contains(identity.source)
    }

    var sourcesTakingAccounts: [SourceID] {
        accountSources.filter { accounts.isLoggedIn($0.id) && $0.account.supportsMultipleAccounts }.map(\.id)
    }

    func toggleAccountSwitcher() {
        withAnimation(accountSwitcherOpen ? Motion.switcherClose : Motion.switcherOpen) { accountSwitcherOpen.toggle() }
    }

    func closeAccountSwitcher() {
        guard accountSwitcherOpen else { return }
        withAnimation(Motion.switcherClose) { accountSwitcherOpen = false }
    }

    /// The switcher's pick: browses its source as that account. A kept account signs in in place
    /// of the one signed in there; the chip shows it at once and goes back if it cannot.
    func browse(as identity: AccountIdentity) {
        withAnimation(Motion.switcherPick) {
            accountSwitcherOpen = false
            selectBrowsingSource(identity.source)
            if identity.kind == .kept { pendingIdentity = identity }
        }
        guard identity.kind == .kept, let userID = identity.userID else { return }
        Task {
            await switchAccount(identity.source, to: userID)
            guard pendingIdentity == identity else { return }
            withAnimation(Motion.switcherPick) { pendingIdentity = nil }
        }
    }

    func signIn(from identity: AccountIdentity) {
        browse(as: identity)
        requestLogin(identity.source)
    }

    func addAccount(from id: SourceID) {
        browse(as: identity(of: id))
        guard accounts.isLoggedIn(id) else {
            requestLogin(id)
            return
        }
        Task {
            if await addAccount(id) { presentLogin(LoginRequest(source: id, adding: true)) }
        }
    }
}

struct AccountChip: View {
    var namespace: Namespace.ID
    var events: AccountSwitcherEvents
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    static let avatarSize: CGFloat = 30

    var body: some View {
        let identity = model.browsingIdentity
        let open = model.accountSwitcherOpen
        Button { model.toggleAccountSwitcher() } label: {
            HStack(spacing: 8) {
                ZStack {
                    ForEach([identity]) { identity in
                        IdentityAvatar(identity: identity, size: Self.avatarSize, busy: identity.kind == .signingIn || model.isSwitching(identity))
                            .matchedGeometryEffect(id: AccountSwitcherPanel.avatarKey(identity), in: namespace)
                            .transition(.chipAvatar)
                    }
                }
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                ZStack(alignment: .leading) {
                    ForEach([identity]) { identity in
                        IdentityLabel(identity: identity, showsVIP: true, captionSize: 10.5)
                            .fixedSize()
                            .transition(.chipLabel)
                    }
                }
                .frame(maxHeight: .infinity)
                // The names roll inside the chip. The avatar is not clipped: it flies in from the
                // switcher below.
                .clipped()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .frame(height: 40)
            .contentShape(Capsule())
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
        .fixedSize()
        .help("账号与平台")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { events.chipFrame = $0 }
        .anchorPreference(key: AccountChipKey.self, value: .bounds) { $0 }
    }
}

/// Where the header's account chip is, for `MainLayout` to hang the switcher from.
struct AccountChipKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct AccountSwitcherPanel: View {
    var namespace: Namespace.ID
    var events: AccountSwitcherEvents
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var held: Held?

    private struct Held {
        var groups: [IdentityGroup]
        var current: AccountIdentity
    }

    static let width: CGFloat = 288
    static let gap: CGFloat = 8

    static func avatarKey(_ identity: AccountIdentity) -> String { "switcher.avatar.\(identity.id)" }

    var body: some View {
        let frozen = model.accountSwitcherOpen ? nil : held
        let current = frozen?.current ?? model.browsingIdentity
        let others = (frozen?.groups ?? model.identityGroups)
            .map { IdentityGroup(source: $0.source, identities: $0.identities.filter { $0.id != current.id }) }
            .filter { !$0.identities.isEmpty }
        let adding = model.sourcesTakingAccounts
        let rows = others.flatMap(\.identities)
        let drop = Dictionary(rows.enumerated().map { ($1.id, $0 + 2) }, uniquingKeysWith: { first, _ in first })
        let last = rows.count + 2
        VStack(alignment: .leading, spacing: 2) {
            CurrentIdentityCard(identity: current)
                .modifier(DropIn(order: 0))
            if !others.isEmpty {
                Text("切换账号")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.85))
                    .padding(.leading, 8)
                    .frame(height: 26, alignment: .bottom)
                    .padding(.top, 4)
                    .modifier(DropIn(order: 1))
                ForEach(Array(others.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { hairline }
                    ForEach(group.identities) { identity in
                        IdentityRow(
                            identity: identity,
                            namespace: namespace,
                            pick: { model.browse(as: identity) },
                            signIn: identity.kind == .signedOut || identity.kind == .expired ? { model.signIn(from: identity) } : nil
                        )
                        .modifier(DropIn(order: drop[identity.id] ?? 2))
                    }
                }
            }
            hairline
            if !adding.isEmpty {
                addAccount(adding).modifier(DropIn(order: last))
            }
            ActionRow(symbol: "gearshape", title: "管理账号…") {
                model.closeAccountSwitcher()
                model.openSettings(.account)
            }
            .modifier(DropIn(order: last + 1))
        }
        .padding(8)
        .frame(width: Self.width)
        .background { surface }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { events.panelFrame = $0 }
        .onChange(of: model.identityGroups, initial: true) { hold() }
        .onChange(of: model.browsingIdentity) { hold() }
    }

    private func hold() {
        guard model.accountSwitcherOpen else { return }
        held = Held(groups: model.identityGroups, current: model.browsingIdentity)
    }

    @ViewBuilder
    private func addAccount(_ sources: [SourceID]) -> some View {
        if sources.count == 1, let id = sources.first {
            ActionRow(symbol: "plus", title: "添加账号…") { model.addAccount(from: id) }
        } else {
            Menu {
                ForEach(sources, id: \.key) { id in
                    Button { model.addAccount(from: id) } label: {
                        Label(model.displayName(of: id), systemImage: model.sourceSymbol(of: id))
                    }
                }
            } label: {
                ActionRowLabel(symbol: "plus", title: "添加账号", trailing: "chevron.right")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.outlineVariant.opacity(0.45))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
    }

    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(theme.surfacePanel.opacity(theme.isDark ? 0.84 : 0.9)))
            .overlay(shape.strokeBorder(theme.onSurface.opacity(theme.isDark ? 0.09 : 0.07), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.42 : 0.14), radius: 26, y: 14)
    }
}

struct AccountSwitcherLayer: View {
    var chip: Anchor<CGRect>?
    var namespace: Namespace.ID
    var events: AccountSwitcherEvents
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            if let chip {
                let rect = geo[chip]
                ZStack(alignment: .topTrailing) {
                    if model.accountSwitcherOpen {
                        AccountSwitcherPanel(namespace: namespace, events: events)
                            .transition(.switcherPanel)
                    }
                }
                .offset(x: rect.maxX - AccountSwitcherPanel.width, y: rect.maxY + AccountSwitcherPanel.gap)
            }
        }
        .background { AccountSwitcherWatch(events: events) }
    }
}

/// Folds the switcher when the page changes or Now Playing covers the shell, and listens for Esc
/// and clicks outside while it is open. A leaf of its own, so only it follows those.
private struct AccountSwitcherWatch: View {
    var events: AccountSwitcherEvents
    @Environment(AppModel.self) private var model

    var body: some View {
        Color.clear
            .onChange(of: model.player.showNowPlaying) { if model.player.showNowPlaying { model.closeAccountSwitcher() } }
            .onChange(of: model.route) { model.closeAccountSwitcher() }
            .onChange(of: model.accountSwitcherOpen, initial: true) {
                if model.accountSwitcherOpen {
                    events.onClose = { [model] in model.closeAccountSwitcher() }
                    events.install()
                } else {
                    events.uninstall()
                }
            }
            .onDisappear { events.uninstall() }
    }
}

private struct CurrentIdentityCard: View {
    var identity: AccountIdentity
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IdentityAvatar(identity: identity, size: 44, busy: identity.kind == .signingIn)
                IdentityLabel(identity: identity, showsVIP: true, titleSize: 15, captionSize: 11.5)
                Spacer(minLength: 0)
                if identity.kind == .signedIn {
                    RefreshButton {
                        await model.refreshAccount(identity.source)
                        await model.refreshUserLibrary(identity.source)
                    }
                }
            }
            actions
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.04)))
    }

    @ViewBuilder
    private var actions: some View {
        switch identity.kind {
        case .signedIn, .kept:
            HStack(spacing: 8) {
                if model.hasUserPages(identity.source) {
                    CardButton(title: "个人主页", symbol: "person.crop.circle") {
                        model.closeAccountSwitcher()
                        model.openProfile(identity.source)
                    }
                }
                CardButton(title: "退出登录", symbol: "rectangle.portrait.and.arrow.right") {
                    model.closeAccountSwitcher()
                    Task { await model.logout(identity.source) }
                }
            }
        case .signedOut, .expired:
            VStack(alignment: .leading, spacing: 10) {
                Text(model.loginBenefits(of: identity.source))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.signIn(from: identity) } label: {
                    Text(identity.kind == .expired ? "重新登录" : "登录")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.onPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(VariantButtonStyle(variant: .filled, isPill: true))
            }
        case .signingIn, .noAccounts:
            EmptyView()
        }
    }
}

private struct CardButton: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.onSurface.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(Capsule().fill(theme.onSurface.opacity(hovering ? 0.11 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(SwitcherPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

private struct RefreshButton: View {
    var refresh: @MainActor () async -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var turns = 0

    var body: some View {
        Button {
            turns += 1
            Task { await refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
                .rotationEffect(.degrees(Double(turns) * 360))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: turns)
                .frame(width: 26, height: 26)
                .background(Circle().fill(theme.onSurface.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help("刷新账号信息")
    }
}

private struct IdentityRow: View {
    var identity: AccountIdentity
    var namespace: Namespace.ID
    var pick: () -> Void
    var signIn: (() -> Void)?
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: pick) {
            HStack(spacing: 10) {
                IdentityAvatar(identity: identity, size: 30)
                    .matchedGeometryEffect(id: AccountSwitcherPanel.avatarKey(identity), in: namespace)
                IdentityLabel(identity: identity, showsVIP: true)
                Spacer(minLength: 6)
                if signIn != nil {
                    Color.clear.frame(width: 40, height: 1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background { if hovering { shape.fill(theme.onSurface.opacity(0.06)) } }
            .contentShape(shape)
        }
        .buttonStyle(SwitcherPressStyle())
        .overlay(alignment: .trailing) {
            if let signIn {
                LoginPill(action: signIn).padding(.trailing, 8)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(identity.hasAccount ? "切换到这个账号" : "浏览\(identity.sourceName)")
    }
}

private struct LoginPill: View {
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("登录")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(theme.accent.opacity(hovering ? 0.22 : 0.13)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

private struct ActionRow: View {
    var symbol: String
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ActionRowLabel(symbol: symbol, title: title)
        }
        .buttonStyle(SwitcherPressStyle())
    }
}

private struct ActionRowLabel: View {
    var symbol: String
    var title: String
    var trailing: String?
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 30)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.onSurface.opacity(0.85))
            Spacer(minLength: 0)
            if let trailing {
                Image(systemName: trailing)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background {
            if hovering { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.onSurface.opacity(0.06)) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

struct IdentityLabel: View {
    var identity: AccountIdentity
    var showsVIP = false
    var titleSize: CGFloat = 13
    var captionSize: CGFloat = 11
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(identity.title)
                    .font(.system(size: titleSize, weight: titleSize > 13 ? .semibold : .medium))
                    .foregroundStyle(identity.hasAccount || identity.kind == .noAccounts ? theme.onSurface : theme.onSurfaceVariant)
                    .lineLimit(1)
                if showsVIP, identity.isVIP {
                    Tag(text: "VIP", style: .red, soft: true)
                }
            }
            if let caption = identity.caption {
                Text(caption)
                    .font(.system(size: captionSize))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.75))
                    .lineLimit(1)
            }
        }
    }
}

struct IdentityAvatar: View {
    var identity: AccountIdentity
    var size: CGFloat
    var busy = false
    @Environment(\.theme) private var theme

    var body: some View {
        face
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if identity.kind != .noAccounts { badge }
            }
            .overlay {
                if busy { SpinningRing(color: theme.accent).padding(-3) }
            }
    }

    @ViewBuilder
    private var face: some View {
        if identity.hasAccount {
            ArtworkView(artwork: identity.avatar ?? Artwork(seed: "avatar"), circle: true, pixelSize: size > 32 ? 140 : 100)
                .overlay(Circle().strokeBorder(theme.onSurface.opacity(0.08), lineWidth: 0.5))
        } else {
            Circle()
                .fill(theme.onSurface.opacity(0.08))
                .overlay {
                    Image(systemName: identity.kind == .noAccounts ? identity.symbol : "person.fill")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(theme.onSurfaceVariant)
                }
        }
    }

    private var badge: some View {
        let diameter = (size * 0.48).rounded()
        return Image(systemName: identity.symbol)
            .font(.system(size: diameter * 0.5, weight: .bold))
            .foregroundStyle(theme.onSurface.opacity(0.78))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(theme.surfaceBright))
            .overlay(Circle().strokeBorder(theme.surface, lineWidth: 1.5))
            .offset(x: size * 0.12, y: size * 0.1)
    }
}

private struct SpinningRing: View {
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .transition(.opacity)
    }
}

private struct DropIn: ViewModifier {
    var order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : -6)
            .onAppear {
                withAnimation(Motion.switcherOpen.delay(Double(min(order, 12)) * 0.022)) { shown = true }
            }
    }
}

/// A label rolling in or out: `progress` 1 in place, 0 `travel` points off (up when negative);
/// it is seen only past `fadeFrom` of the way in.
private struct Roll: ViewModifier, Animatable {
    var progress: Double
    var travel: CGFloat
    var fadeFrom: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(y: travel * (1 - progress))
            .opacity(min(max((progress - fadeFrom) / (1 - fadeFrom), 0), 1))
    }
}

private struct SwitcherPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension AnyTransition {
    static var chipAvatar: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.12)),
            removal: .scale(scale: 0.5).combined(with: .opacity)
        )
    }

    /// The chip's name and source: the new ones roll in from below, where the switcher was, the
    /// old ones roll out above. On the same spring, but the old ones are gone halfway and the new
    /// ones show only once on their way, so the two never sit on each other.
    static var chipLabel: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Roll(progress: 0, travel: 14, fadeFrom: 0.3), identity: Roll(progress: 1, travel: 14, fadeFrom: 0.3)),
            removal: .modifier(active: Roll(progress: 0, travel: -14, fadeFrom: 0.6), identity: Roll(progress: 1, travel: -14, fadeFrom: 0.6))
        )
    }

    static var switcherPanel: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.92, anchor: .topTrailing)
                .combined(with: .offset(y: -6))
                .combined(with: .opacity.animation(.easeOut(duration: 0.1))),
            removal: .scale(scale: 0.96, anchor: .topTrailing)
                .combined(with: .opacity)
                .animation(.easeIn(duration: 0.14))
        )
    }
}

@MainActor
final class AccountSwitcherEvents {
    /// In the window's content coordinates (top-left origin).
    var panelFrame: CGRect = .zero
    var chipFrame: CGRect = .zero
    var onClose: () -> Void = {}
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return false }
            if let editor = (event.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            onClose()
            return true
        }
        guard let window = event.window, let content = window.contentView else {
            onClose()
            return false
        }
        let location = event.locationInWindow
        let point = CGPoint(x: location.x, y: content.bounds.height - location.y)
        if !panelFrame.contains(point) && !chipFrame.contains(point) { onClose() }
        return false
    }
}
