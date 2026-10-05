import Foundation
import MusicSources
import StarryCore

public struct PluginManifest: Sendable, Hashable {
    public static let supportedAPIVersions: ClosedRange<Int> = 1...1

    /// Reverse-DNS, lower case; never changes once installed (`SourceID.plugin(id:)`).
    public var id: String
    public var name: String
    public var version: String
    public var apiVersion: Int
    public var author: String?
    public var description: String?
    public var homepage: URL?
    public var icon: String?
    public var hosts: [String]
    /// The platform whose ids the plugin's songs, albums and lyrics carry, when it is one the
    /// app knows by name (`namespaces`). The plugin then is that platform's source: its `SourceID`
    /// and lyrics provider id are the platform's, so what was saved for the platform (songs,
    /// accounts, settings, lyric matches) stays its, and the AMLL TTML lookup uses its ids.
    public var idNamespace: String?

    public static let namespaces: Set<String> = ["netease", "qqmusic", "kugou"]

    public var sourceID: SourceID { idNamespace.flatMap(SourceID.init(key:)) ?? .plugin(id: id) }

    static func isValidID(_ id: String) -> Bool {
        guard (1...100).contains(id.count) else { return false }
        return id.range(of: #"^[a-z0-9]+([._-][a-z0-9]+)*$"#, options: .regularExpression) != nil
    }
}

struct PluginDescription: Decodable {
    struct Permissions: Decodable {
        var hosts: [String]?
    }

    struct SourceGroup: Decodable {
        var functions: [String]
        var qualityTiers: [WireTier]?
        var webPages: [String: String]?
        var searchKinds: [String]?
        var artistSongOrders: [String]?
        var collectableKinds: [String]?
        var commentSorts: [String]?
        var canLikeComments: Bool?
        var playlistOptions: PlaylistOptions?
        var albumSorts: [String]?
    }

    struct PlaylistOptions: Decodable {
        var description: Bool?
        var privacy: Bool?
        var privateByDefault: Bool?
        var publicIsFinal: Bool?
        var nameLimit: Int?
    }

    struct LyricsGroup: Decodable {
        var functions: [String]
        var detail: String?
        var ttmlFolder: String?
    }

    struct AccountGroup: Decodable {
        struct QRKind: Decodable {
            var id: String
            var title: String
            var appName: String?
        }

        struct Server: Decodable {
            var placeholder: String?
        }

        struct CodeLogin: Decodable {
            var title: String
            var hint: String?
        }

        var functions: [String]
        var methods: [String]?
        var qrKinds: [QRKind]?
        var cookieHint: String?
        var multipleAccounts: Bool?
        /// Sign-in starts with a server address (`connect`).
        var server: Server?
        var passwordOptional: Bool?
        var codeLogin: CodeLogin?
    }

    var id: String?
    var name: String?
    var version: String?
    var apiVersion: Int?
    var author: String?
    var description: String?
    var homepage: String?
    var icon: String?
    var idNamespace: String?
    var permissions: Permissions?
    var settings: [WireSettingsSection]
    var source: SourceGroup?
    var lyrics: LyricsGroup?
    var account: AccountGroup?

    /// The manifest, or why the plugin cannot load.
    func manifest() throws -> PluginManifest {
        guard let id, PluginManifest.isValidID(id) else {
            throw PluginError.load("id 必须是小写字母、数字和 . _ - 组成的反向域名（如 dev.example.music），而不是 \(id.map { "“\($0)”" } ?? "空")")
        }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw PluginError.load("\(id) 没有 name") }
        guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { throw PluginError.load("\(name) 没有 version") }
        guard let apiVersion, PluginManifest.supportedAPIVersions.contains(apiVersion) else {
            throw PluginError.load("\(name) 需要的 apiVersion \(apiVersion.map(String.init) ?? "（未写）") 不受支持，这个版本支持 \(PluginManifest.supportedAPIVersions.lowerBound)")
        }
        guard source != nil || lyrics != nil else { throw PluginError.load("\(name) 既不是音源也不是歌词源（没有导出 source 或 lyrics）") }
        if let source, !source.functions.contains("resolve") { throw PluginError.load("\(name) 的 source 缺少 resolve") }
        if let lyrics, !(lyrics.functions.contains("search") && lyrics.functions.contains("fetch")) {
            throw PluginError.load("\(name) 的 lyrics 需要 search 和 fetch")
        }
        if let account, source == nil || !account.functions.contains("refresh") || !account.functions.contains("logout") {
            throw PluginError.load(source == nil ? "\(name) 的 account 只能和 source 一起导出" : "\(name) 的 account 需要 refresh 和 logout")
        }
        if let account, account.server != nil, !account.functions.contains("connect") {
            throw PluginError.load("\(name) 的 account 写了 server，需要 connect")
        }
        if let account, account.methods?.contains("code") == true, account.codeLogin == nil || !account.functions.contains("beginCodeLogin") || !account.functions.contains("pollCodeLogin") {
            throw PluginError.load("\(name) 的验证码登录（code）需要 codeLogin、beginCodeLogin 和 pollCodeLogin")
        }
        if let idNamespace, !PluginManifest.namespaces.contains(idNamespace) {
            throw PluginError.load("\(name) 的 idNamespace 只能是 \(PluginManifest.namespaces.sorted().joined(separator: "、"))")
        }
        return PluginManifest(
            id: id,
            name: name,
            version: version,
            apiVersion: apiVersion,
            author: author,
            description: description,
            homepage: homepage.flatMap(URL.init(string:)),
            icon: icon,
            hosts: (permissions?.hosts ?? []).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty },
            idNamespace: idNamespace
        )
    }
}

public enum PluginError: Error, Sendable, Equatable, LocalizedError {
    /// The file could not be read, run or understood.
    case load(String)
    case script(plugin: String, code: String?, message: String)
    /// A call did not finish in time.
    case timeout(plugin: String, path: String)
    /// A call returned something that is not what the interface says.
    case badResult(plugin: String, path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .load(let message): "插件无法加载：\(message)"
        case .script(let plugin, _, let message): "\(plugin)：\(message)"
        case .timeout(let plugin, _): "\(plugin) 没有及时响应"
        case .badResult(let plugin, let path, _): "\(plugin) 的 \(path) 返回了无法识别的结果"
        }
    }
}
