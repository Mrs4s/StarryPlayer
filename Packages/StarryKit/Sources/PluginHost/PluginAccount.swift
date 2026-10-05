import Foundation
import MusicSources
import StarryCore

actor PluginAccount: AccountAdapter {
    /// A QR poll may wait on a long poll of the platform's (a minute or so).
    static let pollTimeout: TimeInterval = 100

    nonisolated let supportedMethods: [LoginMethod]
    nonisolated let supportsMultipleAccounts: Bool
    nonisolated let qrLoginKinds: [QRLoginKind]
    nonisolated let manualCredentialHint: String
    nonisolated let serverPrompt: ServerPrompt?
    nonisolated let passwordOptional: Bool
    nonisolated let codeLogin: CodeLoginInfo?

    private let plugin: Plugin
    private let source: SourceID
    private var current: AccountState = .anonymous
    private var continuations: [UUID: AsyncStream<AccountState>.Continuation] = [:]

    init(plugin: Plugin) {
        self.plugin = plugin
        source = plugin.manifest.sourceID
        let group = plugin.description.account
        supportedMethods = (group?.methods ?? []).compactMap(LoginMethod.init(rawValue:))
        supportsMultipleAccounts = (group?.multipleAccounts ?? false) && plugin.has("account.exportCredentials") && plugin.has("account.restoreCredentials")
            && plugin.has("account.signOutLocally")
        qrLoginKinds = (group?.qrKinds ?? []).map { QRLoginKind(id: $0.id, title: $0.title, appName: $0.appName ?? $0.title) }
        manualCredentialHint = group?.cookieHint ?? "粘贴登录用的 Cookie 或令牌"
        serverPrompt = group?.server.map { ServerPrompt(placeholder: $0.placeholder ?? "服务器地址") }
        passwordOptional = group?.passwordOptional ?? false
        codeLogin = group?.codeLogin.map { CodeLoginInfo(title: $0.title, hint: $0.hint ?? "") }
    }

    var state: AccountState { current }

    nonisolated var stateUpdates: AsyncStream<AccountState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id, continuation) }
            continuation.onTermination = { _ in Task { await self.unregister(id) } }
        }
    }

    private func register(_ id: UUID, _ continuation: AsyncStream<AccountState>.Continuation) {
        continuations[id] = continuation
        continuation.yield(current)
    }

    private func unregister(_ id: UUID) { continuations[id] = nil }

    private func set(_ state: AccountState) {
        current = state
        for continuation in continuations.values { continuation.yield(state) }
    }

    private func signedIn(_ profile: WireProfile?) {
        if let profile { set(.loggedIn(profile.profile(source: source))) } else { set(.anonymous) }
    }

    func refresh() async throws {
        var kept: WireProfile?
        if plugin.has("account.current"), let profile: WireProfile? = try? await plugin.call("account.current") { kept = profile }
        if kept != nil { set(.loggingIn) }
        do {
            let profile: WireProfile? = try await plugin.call("account.refresh")
            if let profile {
                set(.loggedIn(profile.profile(source: source)))
            } else if case .expired = current {
            } else {
                set(.anonymous)
            }
        } catch PlaybackError.loginExpired {
            set(.expired)
        } catch {
            if let kept { set(.loggedIn(kept.profile(source: source))) } else if case .loggingIn = current { set(.anonymous) }
            throw error
        }
    }

    func logout() async throws {
        defer { set(.anonymous) }
        let _: JSONValue = try await plugin.call("account.logout")
    }

    func signOutLocally() async {
        if plugin.has("account.signOutLocally") {
            let _: JSONValue? = try? await plugin.call("account.signOutLocally")
        } else {
            let _: JSONValue? = try? await plugin.call("account.logout")
        }
        set(.anonymous)
    }

    func exportCredentials() async -> Data? {
        guard plugin.has("account.exportCredentials"), let credentials: JSONValue = try? await plugin.call("account.exportCredentials"), !credentials.isNull else { return nil }
        return try? JSONEncoder().encode(credentials)
    }

    func restoreCredentials(_ credentials: Data) async throws {
        guard plugin.has("account.restoreCredentials") else { throw SourceError.notImplemented("切换账号") }
        let value = try JSONDecoder().decode(JSONValue.self, from: credentials)
        do {
            try await login("account.restoreCredentials", value)
        } catch {
            await signOutLocally()
            throw error
        }
    }

    func connect(to address: String) async throws -> ServerInfo {
        guard plugin.has("account.connect") else { throw SourceError.notImplemented("连接服务器") }
        let server: WireServerInfo = try await plugin.call("account.connect", address)
        return server.info
    }

    func beginQRLogin() async throws -> QRLoginSession {
        try await beginQRLogin(kind: qrLoginKinds.first ?? QRLoginKind(id: "", title: "", appName: ""))
    }

    func beginQRLogin(kind: QRLoginKind) async throws -> QRLoginSession {
        guard plugin.has("account.beginQRLogin") else { throw SourceError.notImplemented("扫码登录") }
        let session: WireQRSession = try await plugin.call("account.beginQRLogin", kind.id.isEmpty ? nil : kind.id)
        let image = session.image.flatMap { Data(base64Encoded: $0.components(separatedBy: ",").last ?? $0) }
        guard let url = session.url.flatMap(URL.init(string:)) ?? (image != nil ? URL(string: "about:blank") : nil) else {
            throw SourceError.invalidResponse("account.beginQRLogin 没有给出二维码")
        }
        let used = qrLoginKinds.first { $0.id == session.kind } ?? (kind.id.isEmpty ? nil : kind)
        return QRLoginSession(key: session.key, url: url, image: image, kind: used)
    }

    func pollQRLogin(_ session: QRLoginSession) async throws -> QRLoginStatus {
        guard plugin.has("account.pollQRLogin") else { throw SourceError.notImplemented("扫码登录") }
        let poll: WireQRPoll = try await plugin.call("account.pollQRLogin", timeout: Self.pollTimeout, arguments: [WireQRSessionRef(key: session.key, kind: session.kind?.id)])
        return try await status(of: poll)
    }

    private func status(of poll: WireQRPoll) async throws -> QRLoginStatus {
        switch poll.status {
        case "scanned": return .scanned
        case "expired": return .expired
        case "confirmed":
            if let profile = poll.profile {
                set(.loggedIn(profile.profile(source: source)))
            } else {
                try await refresh()
            }
            return .confirmed
        default: return .waiting
        }
    }

    func beginCodeLogin() async throws -> CodeLoginSession {
        guard plugin.has("account.beginCodeLogin") else { throw SourceError.notImplemented("验证码登录") }
        let session: WireCodeSession = try await plugin.call("account.beginCodeLogin")
        return CodeLoginSession(key: session.key, code: session.code)
    }

    func pollCodeLogin(_ session: CodeLoginSession) async throws -> QRLoginStatus {
        guard plugin.has("account.pollCodeLogin") else { throw SourceError.notImplemented("验证码登录") }
        let poll: WireQRPoll = try await plugin.call("account.pollCodeLogin", timeout: Self.pollTimeout, arguments: [WireQRSessionRef(key: session.key, kind: nil)])
        return try await status(of: poll)
    }

    func loginWithCookie(_ cookie: String) async throws {
        guard plugin.has("account.loginWithCookie") else { throw SourceError.notImplemented("Cookie 登录") }
        try await login("account.loginWithCookie", cookie)
    }

    func loginWithPassword(username: String, password: String) async throws {
        guard plugin.has("account.loginWithPassword") else { throw SourceError.notImplemented("账号密码登录") }
        try await login("account.loginWithPassword", username, password)
    }

    func sendPhoneCode(phone: String, countryCode: String) async throws {
        guard plugin.has("account.sendPhoneCode") else { throw SourceError.notImplemented("验证码登录") }
        let _: JSONValue = try await plugin.call("account.sendPhoneCode", phone, countryCode)
    }

    func loginWithPhoneCode(phone: String, countryCode: String, code: String) async throws {
        guard plugin.has("account.loginWithPhoneCode") else { throw SourceError.notImplemented("验证码登录") }
        try await login("account.loginWithPhoneCode", phone, countryCode, code)
    }

    private func login(_ path: String, _ arguments: any Encodable & Sendable...) async throws {
        set(.loggingIn)
        do {
            let profile: WireProfile? = try await plugin.call(path, timeout: nil, arguments: arguments)
            signedIn(profile)
        } catch {
            set(.anonymous)
            throw error
        }
    }
}
