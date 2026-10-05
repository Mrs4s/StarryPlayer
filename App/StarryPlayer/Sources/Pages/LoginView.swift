import AppKit
import CoreImage
import MusicSources
import StarryCore
import SwiftUI

/// Source-specific login methods, with server setup for self-hosted sources.
/// Closing an unfinished add-account flow restores the previous account.
struct LoginView: View {
    var request: LoginRequest
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var picked: Way?
    @State private var attempt = 0
    @State private var status: QRLoginStatus = .waiting
    @State private var qrImage: NSImage?
    @State private var code: String?
    /// The server `connect` reached, for a self-hosted source.
    @State private var server: ServerInfo?
    @State private var serverAddress = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var cookieText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false

    private enum Way: Hashable {
        case qrCode(QRLoginKind?)
        case password
        case code
        case cookie
    }

    var body: some View {
        VStack(spacing: 18) {
            AppMark(size: 48)
            Text(request.adding ? "添加\(sourceName)账号" : "登录\(sourceName)").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.onSurface)

            if let prompt = adapter?.serverPrompt, server == nil {
                serverForm(prompt)
            } else {
                if let server { serverRow(server) }
                if ways.count > 1 {
                    SegmentSwitch(selection: Binding { way ?? ways[0] } set: { select($0) }, options: ways.map { ($0, title(of: $0)) })
                }

                switch way {
                case .qrCode: qrPanel
                case .password: passwordForm
                case .code: codePanel
                case .cookie: cookieForm
                case nil:
                    Text("暂不支持在这里登录\(sourceName)").font(.system(size: 13)).foregroundStyle(theme.onSurfaceVariant)
                }

                if case .qrCode = way {
                    PillButton(title: "刷新二维码", systemName: "arrow.clockwise", variant: .ghost) { attempt += 1 }
                }
                if case .code = way {
                    PillButton(title: "换一个验证码", systemName: "arrow.clockwise", variant: .ghost) { attempt += 1 }
                }
            }
            Button(request.adding ? "取消" : "以访客身份继续") { close() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(width: 380)
        .background(theme.surfaceAlt.ignoresSafeArea())
        .modifier(WindowCancelShortcut { close() })
        .task(id: CodeKey(way: way, attempt: attempt)) {
            switch way {
            case .qrCode(let kind): await pollQRCode(kind: kind)
            case .code: await pollCode()
            default: break
            }
        }
        .onAppear { if serverAddress.isEmpty { serverAddress = UserDefaults.standard.string(forKey: serverDefaultsKey) ?? "" } }
    }

    private struct CodeKey: Hashable {
        var way: Way?
        var attempt: Int
    }

    private func close() { model.closeLogin() }

    private var adapter: (any AccountAdapter)? { model.accountSource(request.source)?.account }
    private var sourceName: String { model.displayName(of: request.source) }

    /// The ways this dialog can sign in, in the order it offers them: none before the server of
    /// a self-hosted source is reached, then those it takes.
    private var ways: [Way] {
        guard let adapter, adapter.serverPrompt == nil || server != nil else { return [] }
        let supported = adapter.supportedMethods.filter { server?.methods?.contains($0) ?? true }
        var ways: [Way] = []
        if supported.contains(.qrCode) {
            let kinds = adapter.qrLoginKinds
            ways += kinds.isEmpty ? [.qrCode(nil)] : kinds.map { .qrCode($0) }
        }
        if supported.contains(.password) { ways.append(.password) }
        if supported.contains(.code), adapter.codeLogin != nil { ways.append(.code) }
        if supported.contains(.cookie) { ways.append(.cookie) }
        return ways
    }

    private var way: Way? { picked.flatMap { ways.contains($0) ? $0 : nil } ?? ways.first }

    private func title(of way: Way) -> String {
        switch way {
        case .qrCode(let kind): kind?.title ?? "扫码"
        case .password: "账号密码"
        case .code: adapter?.codeLogin?.title ?? "验证码"
        case .cookie: "Cookie"
        }
    }

    private func select(_ next: Way) {
        guard next != way else { return }
        error = nil
        picked = next
    }

    private var scanningApp: String {
        if case .qrCode(let kind?) = way { return kind.appName }
        return "\(sourceName) App"
    }

    private var qrPanel: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(.white)
                if let qrImage {
                    Image(nsImage: qrImage).interpolation(.none).resizable().padding(12)
                        .opacity(status == .expired ? 0.15 : 1)
                } else if error == nil {
                    ProgressView()
                }
                if status == .expired {
                    Text("二维码已过期").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                }
                if status == .scanned {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(.green)
                        Text("已扫码，请在手机上确认").font(.system(size: 12, weight: .medium)).foregroundStyle(.black)
                    }
                    .padding(10)
                    .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: 180, height: 180)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(theme.outlineVariant, lineWidth: 1))
            Text(error ?? statusText).font(.system(size: 13)).foregroundStyle(error == nil ? theme.onSurfaceVariant : Color(hex: "#F0625D")).multilineTextAlignment(.center)
        }
    }

    private var statusText: String {
        switch status {
        case .waiting: "使用\(scanningApp)扫码登录"
        case .scanned: "等待手机端确认…"
        case .confirmed: "登录成功"
        case .expired: "点击下方刷新二维码"
        }
    }

    private var serverDefaultsKey: String { "login.server.\(request.source.key)" }

    private func serverForm(_ prompt: ServerPrompt) -> some View {
        VStack(spacing: 10) {
            TextField(prompt.placeholder, text: $serverAddress)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.menu))
                .onSubmit { Task { await connect() } }
            PillButton(title: connecting ? "连接中…" : "连接", systemName: "arrow.right", variant: .secondary) { Task { await connect() } }
                .disabled(connecting || trimmedAddress.isEmpty)
            Text(error ?? "输入\(sourceName)服务器的地址").font(.system(size: 12)).foregroundStyle(error == nil ? theme.onSurfaceVariant : Color(hex: "#F0625D"))
                .multilineTextAlignment(.center)
        }
    }

    /// The server reached, with a way back to the address.
    private func serverRow(_ server: ServerInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 14)).foregroundStyle(theme.onSurfaceVariant).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name ?? server.address).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.onSurface).lineLimit(1)
                Text([server.name == nil ? nil : server.address, server.version].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("更换") {
                self.server = nil
                picked = nil
                error = nil
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.menu))
    }

    private var trimmedAddress: String { serverAddress.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func connect() async {
        guard let adapter, !connecting, !trimmedAddress.isEmpty else { return }
        connecting = true
        defer { connecting = false }
        error = nil
        do {
            let reached = try await adapter.connect(to: trimmedAddress)
            UserDefaults.standard.set(reached.address, forKey: serverDefaultsKey)
            serverAddress = reached.address
            picked = nil
            server = reached
        } catch {
            self.error = ErrorText.describe(error)
        }
    }

    private var codePanel: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(theme.onSurface.opacity(0.05))
                if let code {
                    Text(code)
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .kerning(8)
                        .foregroundStyle(theme.onSurface)
                        .textSelection(.enabled)
                        .opacity(status == .expired ? 0.15 : 1)
                } else if error == nil {
                    ProgressView()
                }
                if status == .expired {
                    Text("验证码已过期").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.onSurface)
                }
            }
            .frame(height: 96)
            Text(error ?? (status == .expired ? "点击下方换一个验证码" : adapter?.codeLogin?.hint ?? ""))
                .font(.system(size: 13)).foregroundStyle(error == nil ? theme.onSurfaceVariant : Color(hex: "#F0625D"))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pollCode() async {
        guard let adapter else { return }
        error = nil
        status = .waiting
        code = nil
        do {
            let session = try await adapter.beginCodeLogin()
            code = session.code
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
                let next = try await adapter.pollCodeLogin(session)
                status = next
                if next == .confirmed {
                    model.showToast("登录成功")
                    close()
                    return
                }
                if next == .expired { return }
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = ErrorText.describe(error)
        }
    }

    private var passwordForm: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                TextField("用户名", text: $username)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                Rectangle().fill(theme.outlineVariant).frame(height: 1)
                SecureField(adapter?.passwordOptional == true ? "密码（没有可不填）" : "密码", text: $password)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .onSubmit { Task { await loginWithPassword() } }
            }
            .font(.system(size: 13))
            .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.menu))
            PillButton(title: busy ? "登录中…" : "登录", systemName: "checkmark", variant: .secondary) { Task { await loginWithPassword() } }
                .disabled(busy || username.isEmpty || (password.isEmpty && adapter?.passwordOptional != true))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color(hex: "#F0625D")) }
        }
    }

    private var cookieForm: some View {
        VStack(spacing: 10) {
            TextEditor(text: $cookieText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 120)
                .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.menu))
            Text(adapter?.manualCredentialHint ?? "").font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
            PillButton(title: busy ? "登录中…" : "使用 Cookie 登录", systemName: "checkmark", variant: .secondary) { Task { await loginWithCookie() } }
                .disabled(busy || cookieText.isEmpty)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color(hex: "#F0625D")) }
        }
    }

    private func pollQRCode(kind: QRLoginKind?) async {
        guard let adapter else { return }
        error = nil
        status = .waiting
        qrImage = nil
        do {
            let session = if let kind { try await adapter.beginQRLogin(kind: kind) } else { try await adapter.beginQRLogin() }
            qrImage = session.image.flatMap(NSImage.init(data:)) ?? QRCode.image(for: session.url.absoluteString, side: 400)
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
                let next = try await adapter.pollQRLogin(session)
                status = next
                if next == .confirmed {
                    model.showToast("登录成功")
                    close()
                    return
                }
                if next == .expired { return }
            }
        } catch {
            // Another code or way took over: its request ended with this one (as
            // `URLError.cancelled` when it was on the network), which is not this code's failure.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = ErrorText.describe(error)
        }
    }

    private func loginWithPassword() async {
        guard let adapter, !busy, !username.isEmpty, !password.isEmpty || adapter.passwordOptional else { return }
        await signIn { try await adapter.loginWithPassword(username: username, password: password) }
    }

    private func loginWithCookie() async {
        guard let adapter else { return }
        await signIn { try await adapter.loginWithCookie(cookieText) }
    }

    private func signIn(_ login: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await login()
            model.showToast("登录成功")
            close()
        } catch {
            self.error = ErrorText.describe(error)
        }
    }
}

enum QRCode {
    static func image(for text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
