import Foundation
import StarryCore

public struct AccountProfile: Sendable, Hashable {
    public var userID: String
    public var nickname: String
    public var avatar: Artwork?
    public var isVIP: Bool
    /// Under the name in account lists: which server the account is on, for a source whose
    /// accounts can be on different servers.
    public var detail: String?

    public init(userID: String, nickname: String, avatar: Artwork? = nil, isVIP: Bool = false, detail: String? = nil) {
        self.userID = userID
        self.nickname = nickname
        self.avatar = avatar
        self.isVIP = isVIP
        self.detail = detail
    }
}

public enum AccountState: Sendable, Hashable {
    case anonymous
    case loggingIn
    case loggedIn(AccountProfile)
    case expired
}

public enum QRLoginStatus: Sendable, Hashable {
    case waiting
    case scanned
    case confirmed
    case expired
}

public struct QRLoginSession: Sendable, Hashable {
    public var key: String
    public var url: URL
    /// The code as the platform drew it (PNG / JPEG), when it gives an image rather than the
    /// content; shown instead of a code made from `url`.
    public var image: Data?
    public var kind: QRLoginKind?

    public init(key: String, url: URL, image: Data? = nil, kind: QRLoginKind? = nil) {
        self.key = key
        self.url = url
        self.image = image
        self.kind = kind
    }
}

public struct QRLoginKind: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var appName: String

    public init(id: String, title: String, appName: String) {
        self.id = id
        self.title = title
        self.appName = appName
    }
}

public enum LoginMethod: String, Sendable, CaseIterable {
    case qrCode
    /// A code shown here that the user enters on a device already signed in (Jellyfin's Quick Connect);
    /// `AccountAdapter.codeLogin` names it.
    case code
    case phoneCode
    case web
    /// A user name and password, as a self-hosted server takes them (on the server `connect`
    /// reached, when the source asks for one).
    case password
    case cookie
}

/// A source whose accounts live on a server the user names (self-hosted): the login window asks
/// for its address first and hands it to `AccountAdapter.connect(to:)`.
public struct ServerPrompt: Sendable, Hashable {
    public var placeholder: String

    public init(placeholder: String) {
        self.placeholder = placeholder
    }
}

/// The server `connect(to:)` reached; the login calls that follow sign in there.
public struct ServerInfo: Sendable, Hashable {
    public var address: String
    public var name: String?
    public var version: String?
    /// The ways this server takes, when fewer than the source's (Quick Connect turned off); nil: all.
    public var methods: [LoginMethod]?

    public init(address: String, name: String? = nil, version: String? = nil, methods: [LoginMethod]? = nil) {
        self.address = address
        self.name = name
        self.version = version
        self.methods = methods
    }
}

public struct CodeLoginInfo: Sendable, Hashable {
    public var title: String
    public var hint: String

    public init(title: String, hint: String) {
        self.title = title
        self.hint = hint
    }
}

public struct CodeLoginSession: Sendable, Hashable {
    public var key: String
    public var code: String

    public init(key: String, code: String) {
        self.key = key
        self.code = code
    }
}

public protocol AccountAdapter: Sendable {
    var supportedMethods: [LoginMethod] { get }
    var supportsMultipleAccounts: Bool { get }
    var state: AccountState { get async }
    var stateUpdates: AsyncStream<AccountState> { get }

    func beginQRLogin() async throws -> QRLoginSession
    var qrLoginKinds: [QRLoginKind] { get }
    func beginQRLogin(kind: QRLoginKind) async throws -> QRLoginSession
    func pollQRLogin(_ session: QRLoginSession) async throws -> QRLoginStatus
    func sendPhoneCode(phone: String, countryCode: String) async throws
    func loginWithPhoneCode(phone: String, countryCode: String, code: String) async throws
    func loginWithPassword(username: String, password: String) async throws
    func loginWithCookie(_ cookie: String) async throws
    /// A server to name before signing in (self-hosted sources), or nil.
    var serverPrompt: ServerPrompt? { get }
    /// Checks the address and keeps the server for the login calls that follow.
    func connect(to address: String) async throws -> ServerInfo
    /// Whether `loginWithPassword` takes an empty password (a server's users without one).
    var passwordOptional: Bool { get }
    var codeLogin: CodeLoginInfo? { get }
    func beginCodeLogin() async throws -> CodeLoginSession
    /// `.scanned` never comes: the code is entered, then confirmed at once.
    func pollCodeLogin(_ session: CodeLoginSession) async throws -> QRLoginStatus
    var manualCredentialHint: String { get }
    func refresh() async throws
    func logout() async throws

    /// The signed-in account's credentials, opaque to the app, or nil when signed out or when
    /// the source cannot keep more than one account.
    func exportCredentials() async -> Data?
    func restoreCredentials(_ credentials: Data) async throws
    /// Signs the account out of this app only, leaving its credentials valid on the platform,
    /// so that kept credentials can bring it back. The default logs out for real: a source that
    /// `supportsMultipleAccounts` must override it.
    func signOutLocally() async
}

public extension AccountAdapter {
    var supportsMultipleAccounts: Bool { false }
    func beginQRLogin() async throws -> QRLoginSession { throw SourceError.notImplemented("扫码登录") }
    var qrLoginKinds: [QRLoginKind] { [] }
    func beginQRLogin(kind: QRLoginKind) async throws -> QRLoginSession { try await beginQRLogin() }
    func pollQRLogin(_ session: QRLoginSession) async throws -> QRLoginStatus { throw SourceError.notImplemented("扫码登录") }
    func sendPhoneCode(phone: String, countryCode: String) async throws { throw SourceError.notImplemented("验证码登录") }
    func loginWithPhoneCode(phone: String, countryCode: String, code: String) async throws { throw SourceError.notImplemented("验证码登录") }
    func loginWithPassword(username: String, password: String) async throws { throw SourceError.notImplemented("账号密码登录") }
    func loginWithCookie(_ cookie: String) async throws { throw SourceError.notImplemented("Cookie 登录") }
    var serverPrompt: ServerPrompt? { nil }
    func connect(to address: String) async throws -> ServerInfo { throw SourceError.notImplemented("连接服务器") }
    var passwordOptional: Bool { false }
    var codeLogin: CodeLoginInfo? { nil }
    func beginCodeLogin() async throws -> CodeLoginSession { throw SourceError.notImplemented("验证码登录") }
    func pollCodeLogin(_ session: CodeLoginSession) async throws -> QRLoginStatus { throw SourceError.notImplemented("验证码登录") }
    var manualCredentialHint: String { "粘贴登录用的 Cookie 或令牌" }
    func exportCredentials() async -> Data? { nil }
    func restoreCredentials(_ credentials: Data) async throws { throw SourceError.notImplemented("切换账号") }
    func signOutLocally() async { try? await logout() }
}

public protocol AccountSource: MusicSource {
    var account: AccountAdapter { get }
}
