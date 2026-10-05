import Foundation
import os
@testable import PluginHost

final class StubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data)

    private static let routes = OSAllocatedUnfairLock(initialState: [String: Handler]())
    private static let seen = OSAllocatedUnfairLock(initialState: [URLRequest]())

    static func route(_ host: String, _ handler: @escaping Handler) {
        routes.withLock { $0[host] = handler }
    }

    static func requests(to host: String) -> [URLRequest] {
        seen.withLock { $0.filter { $0.url?.host == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return routes.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let handler = Self.routes.withLock({ $0[url.host ?? ""] }) else { return }
        var received = request
        if received.httpBody == nil, let stream = received.httpBodyStream {
            received.httpBody = Self.read(stream)
        }
        let recorded = received
        Self.seen.withLock { $0.append(recorded) }
        let answer = handler(recorded)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        if (300..<400).contains(answer.status), let location = answer.headers["Location"], let target = URL(string: location, relativeTo: url) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target.absoluteURL), redirectResponse: response)
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

enum Fixture {
    static func options(storage: URL? = nil, timeout: TimeInterval = 10) -> Plugin.Options {
        Plugin.Options(storageDirectory: storage, appVersion: "9.9", callTimeout: timeout, executionLimit: 1, protocolClasses: [StubProtocol.self])
    }

    static func load(_ script: String, name: String = "fixture.js", storage: URL? = nil, timeout: TimeInterval = 10) throws -> Plugin {
        try Plugin.load(script: script, file: URL(fileURLWithPath: "/fixtures/\(name)"), options: options(storage: storage, timeout: timeout))
    }

    static func plugin(id: String = "test.fixture", hosts: [String] = ["api.test"], _ body: String, storage: URL? = nil, timeout: TimeInterval = 10) throws -> Plugin {
        let hostList = hosts.map { "'\($0)'" }.joined(separator: ", ")
        return try load("""
        module.exports = {
          id: '\(id)', name: 'Fixture', version: '1.0.0', apiVersion: 1,
          permissions: { hosts: [\(hostList)] },
          source: { async resolve() { return { url: 'https://cdn.test/a.mp3' }; } },
          \(body)
        };
        """, storage: storage, timeout: timeout)
    }

    static var examples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../plugins/examples").standardizedFileURL
    }

    static var builtIn: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../build/plugins").standardizedFileURL
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "starry-plugin-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

struct AnyJSON: Decodable {
    let value: Any

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let number = try? container.decode(Double.self) { value = number }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyJSON].self) { value = array.map(\.value) }
        else { value = try container.decode([String: AnyJSON].self).mapValues(\.value) }
    }

    subscript(key: String) -> Any? { (value as? [String: Any])?[key] }
}
