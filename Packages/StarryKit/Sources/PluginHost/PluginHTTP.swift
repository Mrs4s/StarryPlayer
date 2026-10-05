import Foundation
import JavaScriptCore
import os

final class PluginHTTP: Sendable {
    struct Request: Sendable {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data?
        var timeout: TimeInterval
        var followsRedirects: Bool
        var wantsBytes: Bool
        var proxy: URL?
        var handlesCookies: Bool

        init(_ options: JSValue) throws {
            guard let text = options.forProperty("url").toString(), let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                throw Failure.badURL(options.forProperty("url").toString() ?? "")
            }
            self.url = url
            method = options.forProperty("method").toString() ?? "GET"
            var headers: [String: String] = [:]
            if let object = options.forProperty("headers"), object.isObject {
                for (key, value) in object.toDictionary() ?? [:] {
                    headers[String(describing: key)] = String(describing: value)
                }
            }
            self.headers = headers
            body = HostFunctions.data(options.forProperty("body"))
            let timeout = options.forProperty("timeout").toDouble()
            self.timeout = timeout.isFinite && timeout > 0 ? min(timeout, 120) : 15
            followsRedirects = options.forProperty("redirect").toString() != "manual"
            wantsBytes = options.forProperty("bytes").toBool()
            proxy = nil
            if let value = options.forProperty("proxy"), value.isString, let text = value.toString()?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                guard let proxy = URL(string: text), ["http", "https", "socks5"].contains(proxy.scheme?.lowercased() ?? ""), proxy.host != nil, proxy.port != nil else {
                    throw Failure.badProxy(text)
                }
                self.proxy = proxy
            }
            handlesCookies = options.forProperty("cookies").map { $0.isUndefined || $0.toBool() } ?? true
        }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var url: URL
        var body: Data
        var textEncodingName: String?
        var cookies: [String: String] = [:]

        func value(in context: JSContext, bytes: Bool) -> JSValue {
            let value = JSValue(newObjectIn: context)!
            value.setValue(status, forProperty: "status")
            value.setValue(headers, forProperty: "headers")
            value.setValue(cookies, forProperty: "cookies")
            value.setValue(url.absoluteString, forProperty: "url")
            if bytes {
                value.setValue(HostFunctions.bytes(body, in: context), forProperty: "body")
            } else {
                value.setValue(text, forProperty: "body")
            }
            return value
        }

        /// The body in the charset the response names, else UTF-8, else Latin-1.
        var text: String {
            if let name = textEncodingName {
                let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
                if encoding != kCFStringEncodingInvalidId,
                   let text = String(data: body, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                    return text
                }
            }
            return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) ?? ""
        }
    }

    enum Failure: Error, LocalizedError {
        case badURL(String)
        case badProxy(String)
        case hostNotAllowed(String)
        case transport(String)
        case timedOut

        var code: String {
            switch self {
            case .badURL, .badProxy: "badRequest"
            case .hostNotAllowed: "hostNotAllowed"
            case .transport: "network"
            case .timedOut: "timeout"
            }
        }

        var errorDescription: String? {
            switch self {
            case .badURL(let url): "不是 http(s) 地址：\(url)"
            case .badProxy(let proxy): "代理地址应为 http://主机:端口 或 socks5://主机:端口，而不是 \(proxy)"
            case .timedOut: "请求超时"
            case .hostNotAllowed(let host): "没有访问 \(host) 的权限（在 permissions.hosts 里声明）"
            case .transport(let message): "网络错误：\(message)"
            }
        }
    }

    private let session: URLSession
    private let proxied = OSAllocatedUnfairLock(initialState: [URL: URLSession]())
    nonisolated(unsafe) private let protocolClasses: [AnyClass]
    private let allowed = OSAllocatedUnfairLock(initialState: [String]())

    init(protocolClasses: [AnyClass] = []) {
        self.protocolClasses = protocolClasses
        session = URLSession(configuration: Self.configuration(protocolClasses: protocolClasses, cookies: nil, proxy: nil))
    }

    deinit {
        session.invalidateAndCancel()
        proxied.withLock { sessions in sessions.values.forEach { $0.invalidateAndCancel() } }
    }

    private static func configuration(protocolClasses: [AnyClass], cookies: HTTPCookieStorage?, proxy: URL?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        if let cookies { configuration.httpCookieStorage = cookies }
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForResource = 120
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? []) }
        if let proxy, let host = proxy.host, let port = proxy.port {
            configuration.connectionProxyDictionary = proxy.scheme?.lowercased() == "socks5"
                ? [kCFProxyTypeKey: kCFProxyTypeSOCKS, kCFStreamPropertySOCKSProxyHost: host, kCFStreamPropertySOCKSProxyPort: port]
                : [kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: host, kCFNetworkProxiesHTTPPort: port,
                   kCFNetworkProxiesHTTPSEnable: true, kCFNetworkProxiesHTTPSProxy: host, kCFNetworkProxiesHTTPSPort: port]
        }
        return configuration
    }

    private func session(for proxy: URL?) -> URLSession {
        guard let proxy else { return session }
        return proxied.withLock { sessions in
            if let existing = sessions[proxy] { return existing }
            // A plugin that switches proxies often should not pile sessions up.
            if sessions.count >= 4 {
                sessions.values.forEach { $0.finishTasksAndInvalidate() }
                sessions.removeAll()
            }
            let made = URLSession(configuration: Self.configuration(protocolClasses: protocolClasses, cookies: session.configuration.httpCookieStorage, proxy: proxy))
            sessions[proxy] = made
            return made
        }
    }

    var hosts: [String] { allowed.withLock { $0 } }

    func allow(_ hosts: [String]) {
        allowed.withLock { $0 = hosts }
    }

    func perform(_ request: Request) async throws -> Response {
        let hosts = hosts
        guard Self.allows(request.url, hosts: hosts) else { throw Failure.hostNotAllowed(request.url.host ?? request.url.absoluteString) }
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = request.handlesCookies
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        let policy = RedirectPolicy(hosts: hosts, follows: request.followsRedirects)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session(for: request.proxy).data(for: urlRequest, delegate: policy)
        } catch {
            if let blocked = policy.blockedHost { throw Failure.hostNotAllowed(blocked) }
            if (error as? URLError)?.code == .timedOut { throw Failure.timedOut }
            throw Failure.transport((error as NSError).localizedDescription)
        }
        if let blocked = policy.blockedHost { throw Failure.hostNotAllowed(blocked) }
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        var fields: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            headers[String(describing: key).lowercased()] = String(describing: value)
            fields[String(describing: key)] = String(describing: value)
        }
        var cookies: [String: String] = [:]
        let now = Date()
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: response.url ?? request.url) {
            cookies[cookie.name] = cookie.expiresDate.map { $0 <= now } == true ? "" : cookie.value
        }
        return Response(status: http?.statusCode ?? 0, headers: headers, url: response.url ?? request.url, body: data, textEncodingName: response.textEncodingName, cookies: cookies)
    }

    static func allows(_ url: URL, hosts: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return hosts.contains { pattern in
            if pattern == "*" { return true }
            if pattern.hasPrefix("*.") {
                let domain = String(pattern.dropFirst(2))
                return host == domain || host.hasSuffix(".\(domain)")
            }
            return host == pattern
        }
    }
}

/// Stops a redirect the request does not follow or that leaves the allowed hosts; the first
/// such host is remembered so the call fails with it.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    private let hosts: [String]
    private let follows: Bool
    private let blocked = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(hosts: [String], follows: Bool) {
        self.hosts = hosts
        self.follows = follows
    }

    var blockedHost: String? { blocked.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard follows else { return nil }
        guard let url = request.url, PluginHTTP.allows(url, hosts: hosts) else {
            blocked.withLock { $0 = $0 ?? request.url?.host ?? "?" }
            return nil
        }
        return request
    }
}
