import Foundation
import LyricsProviders
import Security
import StarryCore
import MusicSources
import Testing
@testable import PluginHost

@Suite struct PluginLoadingTests {
    @Test func readsTheManifest() throws {
        let plugin = try Fixture.plugin("""
        author: 'someone', description: '测试', homepage: 'https://example.com', icon: 'star',
        """)
        #expect(plugin.manifest == PluginManifest(id: "test.fixture", name: "Fixture", version: "1.0.0", apiVersion: 1, author: "someone", description: "测试",
                                                   homepage: URL(string: "https://example.com"), icon: "star", hosts: ["api.test"]))
        #expect(plugin.isSource)
        #expect(!plugin.isLyricsProvider)
        #expect(plugin.has("source.resolve"))
    }

    @Test func takesAnESModuleDefaultExport() throws {
        let plugin = try Fixture.load("""
        exports.default = { id: 'test.esm', name: 'ESM', version: '1', apiVersion: 1, permissions: { hosts: [] },
          lyrics: { async search() { return []; }, async fetch() { return null; } } };
        """)
        #expect(plugin.manifest.id == "test.esm")
        #expect(plugin.isLyricsProvider)
    }

    @Test(arguments: [
        ("module.exports = { name: 'x', version: '1', apiVersion: 1, source: { resolve() {} } }", "id"),
        ("module.exports = { id: 'Bad ID', name: 'x', version: '1', apiVersion: 1, source: { resolve() {} } }", "id"),
        ("module.exports = { id: 'a.b', name: 'x', version: '1', apiVersion: 2, source: { resolve() {} } }", "apiVersion"),
        ("module.exports = { id: 'a.b', name: 'x', version: '1', apiVersion: 1 }", "source"),
        ("module.exports = { id: 'a.b', name: 'x', version: '1', apiVersion: 1, source: { search() {} } }", "resolve"),
        ("module.exports = { id: 'a.b', name: 'x', version: '1', apiVersion: 1, lyrics: { search() {} } }", "fetch"),
        ("throw new Error('boom')", "boom"),
        ("module.exports = {", "fixture.js"),
    ])
    func rejectsWhatIsNotAPlugin(script: String, mentions: String) {
        #expect {
            try Fixture.load(script)
        } throws: { error in
            guard case .load(let message) = error as? PluginError else { return false }
            return message.contains(mentions)
        }
    }

    @Test func managerSkipsBrokenFilesAndDuplicateIDs() throws {
        let directory = Fixture.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = "module.exports = { id: 'a.b', name: 'A', version: '1', apiVersion: 1, permissions: { hosts: [] }, source: { resolve() {} } };"
        try good.write(to: directory.appending(path: "1-good.js"), atomically: true, encoding: .utf8)
        try good.write(to: directory.appending(path: "2-again.js"), atomically: true, encoding: .utf8)
        try "nope(".write(to: directory.appending(path: "3-broken.js"), atomically: true, encoding: .utf8)
        try "ignored".write(to: directory.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        let manager = PluginManager(paths: [directory], options: Fixture.options())
        #expect(manager.plugins.map(\.manifest.id) == ["a.b"])
        #expect(manager.failures.map(\.file.lastPathComponent) == ["3-broken.js"])
        // A second copy of an id is not an error: the first one found replaced it.
        #expect(manager.replaced["a.b"]?.map(\.lastPathComponent) == ["2-again.js"])
    }

    /// Installed copies come before built-in ones; a plugin turned off is listed but gives
    /// nothing, and does not hold its platform against one that is on.
    @Test func managerOriginsAndSwitches() throws {
        let installed = Fixture.temporaryDirectory()
        let builtIn = Fixture.temporaryDirectory()
        for directory in [installed, builtIn] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func plugin(_ id: String, version: String, namespace: String? = nil) -> String {
            "module.exports = { id: '\(id)', name: '\(id)', version: '\(version)', apiVersion: 1, \(namespace.map { "idNamespace: '\($0)', " } ?? "")permissions: { hosts: [] }, source: { resolve() {} } };"
        }
        try plugin("x.music", version: "2").write(to: installed.appending(path: "x.js"), atomically: true, encoding: .utf8)
        try plugin("x.music", version: "1").write(to: builtIn.appending(path: "x.js"), atomically: true, encoding: .utf8)
        try plugin("a.qq", version: "1", namespace: "qqmusic").write(to: installed.appending(path: "a.js"), atomically: true, encoding: .utf8)
        try plugin("b.qq", version: "1", namespace: "qqmusic").write(to: builtIn.appending(path: "b.js"), atomically: true, encoding: .utf8)
        let locations = [PluginManager.Location(installed, origin: .installed), PluginManager.Location(builtIn, origin: .builtIn)]

        let all = PluginManager(locations: locations, options: Fixture.options())
        #expect(all.plugins.map(\.manifest.id) == ["a.qq", "x.music"])
        #expect(all.plugin(id: "x.music")?.manifest.version == "2")
        #expect(all.plugin(id: "x.music").map(all.origin(of:)) == .installed)
        #expect(all.failures.map(\.file.lastPathComponent) == ["b.js"])
        #expect(all.failures.first?.origin == .builtIn)

        let switched = PluginManager(locations: locations, options: Fixture.options(), disabled: ["a.qq"])
        #expect(switched.plugins.map(\.manifest.id) == ["a.qq", "x.music", "b.qq"])
        #expect(switched.enabledPlugins.map(\.manifest.id) == ["x.music", "b.qq"])
        #expect(switched.sources { _ in SourceSettingValues() }.map(\.id) == [.plugin(id: "x.music"), .qqMusic])
        #expect(switched.plugin(id: "b.qq").map(switched.origin(of:)) == .builtIn)
        #expect(switched.failures.isEmpty)
    }

    @Test func developmentPluginsComeFirst() throws {
        let data = Fixture.temporaryDirectory()
        let development = Fixture.temporaryDirectory()
        let builtIn = Fixture.temporaryDirectory()
        for directory in [development, builtIn] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func plugin(_ version: String) -> String {
            "module.exports = { id: 'x.music', name: 'x', version: '\(version)', apiVersion: 1, permissions: { hosts: [] }, source: { resolve() {} } };"
        }
        let file = development.appending(path: "x.js")
        try plugin("dev").write(to: file, atomically: true, encoding: .utf8)
        try plugin("1").write(to: builtIn.appending(path: "x.js"), atomically: true, encoding: .utf8)

        let manager = PluginManager.installed(data: DataDirectory(url: data), appVersion: "1", builtIn: builtIn, development: [file])
        #expect(manager.plugin(id: "x.music")?.manifest.version == "dev")
        #expect(manager.plugin(id: "x.music").map(manager.origin(of:)) == .development)
    }

    /// A platform has one source and one lyrics provider: a lyrics-only plugin stands for it next
    /// to the source plugin, a second lyrics provider for it does not load.
    @Test func managerSharesAPlatformBetweenRoles() throws {
        let directory = Fixture.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func plugin(_ id: String, _ groups: String) -> String {
            "module.exports = { id: '\(id)', name: '\(id)', version: '1', apiVersion: 1, idNamespace: 'qqmusic', permissions: { hosts: [] }, \(groups) };"
        }
        let lyrics = "lyrics: { search() { return []; }, fetch() { return null; } }"
        try plugin("a.lyrics", lyrics).write(to: directory.appending(path: "1.js"), atomically: true, encoding: .utf8)
        try plugin("b.source", "source: { resolve() {} }").write(to: directory.appending(path: "2.js"), atomically: true, encoding: .utf8)
        try plugin("c.both", "source: { resolve() {} }, \(lyrics)").write(to: directory.appending(path: "3.js"), atomically: true, encoding: .utf8)
        try plugin("d.lyrics", lyrics).write(to: directory.appending(path: "4.js"), atomically: true, encoding: .utf8)

        let manager = PluginManager(paths: [directory], options: Fixture.options())
        #expect(manager.plugins.map(\.manifest.id) == ["a.lyrics", "b.source"])
        #expect(manager.failures.map(\.file.lastPathComponent) == ["3.js", "4.js"])
        #expect(manager.failures.last?.message.contains("qqmusic的歌词 已由 a.lyrics（1.js）提供") == true)
        #expect(manager.sources { _ in SourceSettingValues() }.map(\.id) == [.qqMusic])
        #expect(manager.lyricsProviders(cache: LyricsCache(directory: nil)) { _ in SourceSettingValues() }.map(\.id) == [.qqmusic])
        #expect(manager.plugin(id: "a.lyrics")?.settingsID == .plugin(id: "a.lyrics"))
        #expect(manager.plugin(id: "b.source")?.settingsID == .qqMusic)

        let switched = PluginManager(paths: [directory], options: Fixture.options(), disabled: ["a.lyrics", "b.source"])
        #expect(switched.enabledPlugins.map(\.manifest.id) == ["c.both"])
        #expect(switched.failures.map(\.file.lastPathComponent) == ["4.js"])
    }

    @Test func builtInPluginsLoadTogether() throws {
        let manager = PluginManager(locations: [PluginManager.Location(Fixture.builtIn, origin: .builtIn)], options: Fixture.options())
        #expect(manager.failures.isEmpty, "\(manager.failures)")
        #expect(manager.plugins.map(\.manifest.id) == ["moe.mrs4s.jellyfin", "moe.mrs4s.kugou-lyrics", "moe.mrs4s.netease", "moe.mrs4s.qqmusic-lyrics", "moe.mrs4s.subsonic"])
        #expect(manager.sources { _ in SourceSettingValues() }.map(\.id) == [.plugin(id: "moe.mrs4s.jellyfin"), .netease, .plugin(id: "moe.mrs4s.subsonic")])
        #expect(manager.lyricsProviders(cache: LyricsCache(directory: nil)) { _ in SourceSettingValues() }.map(\.id) == [LyricsProviderID(plugin: "moe.mrs4s.jellyfin"), .kugou, .netease, .qqmusic, LyricsProviderID(plugin: "moe.mrs4s.subsonic")])
        let editing = Dictionary(uniqueKeysWithValues: manager.sources { _ in SourceSettingValues() }.map { ($0.id, $0.playlistEditing) })
        for source in editing.values {
            #expect(source.canCreate && source.canEdit && source.canDelete && source.canAdd && source.canRemove && source.canReorder)
        }
        #expect(editing[.netease].map { $0.keepsDescription && $0.keepsPrivacy && $0.publicIsFinal && $0.nameLimit == 40 } == true)
        #expect(editing[.plugin(id: "moe.mrs4s.jellyfin")].map { !$0.keepsDescription && $0.keepsPrivacy && $0.privateByDefault } == true)
        #expect(editing[.plugin(id: "moe.mrs4s.subsonic")].map { $0.keepsDescription && $0.keepsPrivacy && $0.privateByDefault } == true)
    }

    @Test func installerWritesByID() throws {
        let directory = Fixture.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appending(path: "old-name.js")
        try "module.exports = {};".write(to: old, atomically: true, encoding: .utf8)
        let package = try PluginInstaller.inspect(script: "module.exports = { id: 'dev.x', name: 'X', version: '3', apiVersion: 1, permissions: { hosts: ['x.test'] }, lyrics: { search() {}, fetch() {} } };", name: "x.js")
        #expect(package.manifest.id == "dev.x" && package.manifest.hosts == ["x.test"])
        #expect(package.isLyricsProvider && !package.isSource && !package.hasAccount)
        let file = try PluginInstaller.install(package, into: directory, replacing: old)
        #expect(file.lastPathComponent == "dev.x.js")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(PluginManager(paths: [directory], options: Fixture.options()).plugins.map(\.manifest.version) == ["3"])
        #expect(throws: PluginError.self) { try PluginInstaller.inspect(script: "module.exports = { id: 'Bad Id' };", name: "bad.js") }
    }

    @Test func examplesLoad() throws {
        let manager = PluginManager(paths: [Fixture.examples], options: Fixture.options())
        #expect(manager.failures.isEmpty, "\(manager.failures)")
        #expect(Set(manager.plugins.map(\.manifest.id)) == ["co.audius.source", "net.lrclib.lyrics"])
    }
}

@Suite struct PluginHostAPITests {
    @Test func webGlobals() async throws {
        let plugin = try Fixture.plugin("""
        test: {
          async globals() {
            const order = [];
            await new Promise((resolve) => setTimeout(() => { order.push('timeout'); resolve(); }, 5));
            queueMicrotask(() => order.push('microtask'));
            await null;
            const url = new URL('/path/a b?x=1#top', 'https://Example.com:8443/base/');
            url.searchParams.append('q', '晴天 & 雨');
            const params = new URLSearchParams({ a: '1', b: 'x y' });
            params.set('a', '2');
            return {
              order,
              utf8: Array.from(new TextEncoder().encode('é')),
              gbk: new TextDecoder('gbk').decode(new Uint8Array([0xC4, 0xE3, 0xBA, 0xC3])),
              base64: btoa('hello'),
              unbase64: atob('aGVsbG8='),
              href: url.href,
              host: url.host,
              search: url.search,
              params: params.toString(),
              hex: starry.encoding.hex.encode(starry.encoding.hex.decode('00ff10')),
              plugin: starry.plugin.id,
              app: starry.app.version,
            };
          },
        },
        """)
        let result: AnyJSON = try await plugin.call("test.globals")
        #expect(result["order"] as? [String] == ["timeout", "microtask"])
        #expect(result["utf8"] as? [Double] == [0xC3, 0xA9])
        #expect(result["gbk"] as? String == "你好")
        #expect(result["base64"] as? String == "aGVsbG8=")
        #expect(result["unbase64"] as? String == "hello")
        #expect(result["href"] as? String == "https://example.com:8443/path/a%20b?x=1&q=%E6%99%B4%E5%A4%A9+%26+%E9%9B%A8#top")
        #expect(result["host"] as? String == "example.com:8443")
        #expect(result["search"] as? String == "?x=1&q=%E6%99%B4%E5%A4%A9+%26+%E9%9B%A8")
        #expect(result["params"] as? String == "a=2&b=x+y")
        #expect(result["hex"] as? String == "00ff10")
        #expect(result["plugin"] as? String == "test.fixture")
        #expect(result["app"] as? String == "9.9")
    }

    @Test func digestsAndCiphers() async throws {
        let plugin = try Fixture.plugin("""
        test: {
          crypto() {
            const c = starry.crypto, hex = starry.encoding.hex;
            const key = hex.decode('2b7e151628aed2a6abf7158809cf4f3c');
            const block = hex.decode('6bc1bee22e409f96e93d7e117393172a');
            const gcmKey = c.randomBytes(32), nonce = c.randomBytes(12);
            const sealed = c.aes.encrypt({ mode: 'gcm', key: gcmKey, iv: nonce, data: 'secret' });
            const desKey = 'abcdefgh';
            return {
              md5: c.md5('abc', 'hex'),
              sha1: c.sha1('abc', 'hex'),
              sha256: c.sha256('abc', 'hex'),
              hmac: c.hmac('sha256', 'key', 'The quick brown fox jumps over the lazy dog', 'hex'),
              ecb: c.aes.encrypt({ mode: 'ecb', key, data: block, padding: false, out: 'hex' }),
              cbc: c.aes.encrypt({ mode: 'cbc', key, iv: hex.decode('000102030405060708090a0b0c0d0e0f'), data: block, padding: false, out: 'hex' }),
              roundTrip: c.aes.decrypt({ mode: 'cbc', key, data: c.aes.encrypt({ key, data: '你好，世界' }), out: 'utf8' }),
              gcm: c.aes.decrypt({ mode: 'gcm', key: gcmKey, iv: nonce, data: sealed, out: 'utf8' }),
              gcmLength: sealed.length,
              des: c.des.decrypt({ mode: 'ecb', key: desKey, data: c.des.encrypt({ mode: 'ecb', key: desKey, data: 'eight by' }), out: 'utf8' }),
              tripleDES: c.tripleDES.decrypt({ key: '0123456789abcdef', data: c.tripleDES.encrypt({ key: '0123456789abcdef', data: 'x' }), out: 'utf8' }),
              random: c.randomBytes(16).length,
            };
          },
          badKey() { return starry.crypto.aes.encrypt({ key: 'short', data: 'x' }); },
        },
        """)
        let result: AnyJSON = try await plugin.call("test.crypto")
        #expect(result["md5"] as? String == "900150983cd24fb0d6963f7d28e17f72")
        #expect(result["sha1"] as? String == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(result["sha256"] as? String == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(result["hmac"] as? String == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        #expect(result["ecb"] as? String == "3ad77bb40d7a3660a89ecaf32466ef97")
        #expect(result["cbc"] as? String == "7649abac8119b246cee98e9b12e9197d")
        #expect(result["roundTrip"] as? String == "你好，世界")
        #expect(result["gcm"] as? String == "secret")
        #expect(result["gcmLength"] as? Double == 22.0)
        #expect(result["des"] as? String == "eight by")
        #expect(result["tripleDES"] as? String == "x")
        #expect(result["random"] as? Double == 16)
        await #expect(throws: PluginError.self) { let _: AnyJSON = try await plugin.call("test.badKey") }
    }

    @Test(arguments: [false, true])
    func rsaEncryptsForThePrivateKey(spki: Bool) async throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let der = spki ? Self.subjectPublicKeyInfo(pkcs1) : pkcs1
        let label = spki ? "PUBLIC KEY" : "RSA PUBLIC KEY"
        let pem = "-----BEGIN \(label)-----\n\(der.base64EncodedString(options: .lineLength64Characters))\n-----END \(label)-----"
        let plugin = try Fixture.plugin("""
        test: {
          rsa(pem, padding) { return starry.crypto.rsa.encrypt({ publicKey: pem, data: 'hello rsa', padding, out: 'base64' }); },
        },
        """)
        for (padding, algorithm) in [("pkcs1", SecKeyAlgorithm.rsaEncryptionPKCS1), ("oaep", .rsaEncryptionOAEPSHA1), ("none", .rsaEncryptionRaw)] {
            let encrypted: String = try await plugin.call("test.rsa", pem, padding)
            let data = try #require(Data(base64Encoded: encrypted))
            let decrypted = try #require(SecKeyCreateDecryptedData(privateKey, algorithm, data as CFData, nil) as Data?)
            #expect(String(decoding: padding == "none" ? decrypted.drop { $0 == 0 } : decrypted, as: UTF8.self) == "hello rsa", "\(padding)")
        }
    }

    static func subjectPublicKeyInfo(_ pkcs1: Data) -> Data {
        func element(_ tag: UInt8, _ body: Data) -> Data {
            var length = Data()
            if body.count < 0x80 {
                length.append(UInt8(body.count))
            } else {
                var count = body.count
                var bytes: [UInt8] = []
                while count > 0 { bytes.insert(UInt8(count & 0xFF), at: 0); count >>= 8 }
                length.append(0x80 | UInt8(bytes.count))
                length.append(contentsOf: bytes)
            }
            return Data([tag]) + length + body
        }
        let algorithm = element(0x30, Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]))
        return element(0x30, algorithm + element(0x03, Data([0]) + pkcs1))
    }

    @Test func zlibRoundTrips() async throws {
        let plugin = try Fixture.plugin("""
        test: {
          zlib() {
            const text = '歌词'.repeat(100);
            return ['zlib', 'gzip', 'raw'].map((format) => {
              const packed = starry.zlib.deflate(text, { format });
              return [packed.length < 600, starry.zlib.inflate(packed, 'utf8') === text];
            });
          },
        },
        """)
        let result: [[Bool]] = try await plugin.call("test.zlib")
        #expect(result == [[true, true], [true, true], [true, true]])
    }

    @Test func storageOutlivesThePlugin() async throws {
        let directory = Fixture.temporaryDirectory()
        let body = """
        test: {
          write() { starry.storage.set('token', { value: 'abc', n: 1 }); starry.storage.set('gone', 1); starry.storage.remove('gone'); },
          read() { return { token: starry.storage.get('token'), keys: starry.storage.keys() }; },
        },
        """
        let first = try Fixture.plugin(body, storage: directory)
        let _: AnyJSON = try await first.call("test.write")
        try await Task.sleep(for: .milliseconds(800))
        let second = try Fixture.plugin(body, storage: directory)
        let result: AnyJSON = try await second.call("test.read")
        #expect((result["token"] as? [String: Any])?["value"] as? String == "abc")
        #expect(result["keys"] as? [String] == ["token"])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "test.fixture.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func httpReachesOnlyAllowedHosts() async throws {
        StubProtocol.route("api.test") { request in
            if request.url?.path == "/redirect" { return (302, ["Location": "https://evil.test/steal"], Data()) }
            let body = """
            {"method":"\(request.httpMethod ?? "")","query":"\(request.url?.query ?? "")","ua":"\(request.value(forHTTPHeaderField: "User-Agent") ?? "")","type":"\(request.value(forHTTPHeaderField: "Content-Type") ?? "")","body":\(String(decoding: request.httpBody ?? Data("null".utf8), as: UTF8.self))}
            """
            return (200, ["Content-Type": "application/json"], Data(body.utf8))
        }
        StubProtocol.route("evil.test") { _ in (200, [:], Data("stolen".utf8)) }
        let plugin = try Fixture.plugin("""
        test: {
          async get() {
            const response = await starry.http.get('https://api.test/echo', { query: { q: '晴天', n: 2 }, headers: { 'User-Agent': 'fixture' }, responseType: 'json' });
            return { status: response.status, body: response.body, type: response.headers['content-type'] };
          },
          async post() { return (await starry.http.post('https://api.test/echo', { a: 1 }, { responseType: 'json' })).body; },
          async fetch() { const response = await fetch('https://api.test/echo'); return { ok: response.ok, json: await response.json() }; },
          async evil() { return (await starry.http.get('https://evil.test/')).body; },
          async redirect() { return (await starry.http.get('https://api.test/redirect')).status; },
        },
        """)
        let get: AnyJSON = try await plugin.call("test.get")
        #expect(get["status"] as? Double == 200)
        #expect(get["type"] as? String == "application/json")
        let echo = try #require(get["body"] as? [String: Any])
        #expect(echo["method"] as? String == "GET")
        #expect(echo["query"] as? String == "q=%E6%99%B4%E5%A4%A9&n=2")
        #expect(echo["ua"] as? String == "fixture")

        let post: AnyJSON = try await plugin.call("test.post")
        #expect(post["method"] as? String == "POST")
        #expect(post["type"] as? String == "application/json")
        #expect((post["body"] as? [String: Any])?["a"] as? Double == 1)

        let fetched: AnyJSON = try await plugin.call("test.fetch")
        #expect(fetched["ok"] as? Bool == true)

        for path in ["test.evil", "test.redirect"] {
            await #expect("\(path)") {
                let _: AnyJSON = try await plugin.call(path)
            } throws: { error in
                guard case .network(let message) = error as? SourceError else { return false }
                return message.contains("evil.test")
            }
        }
        #expect(StubProtocol.requests(to: "evil.test").isEmpty)
    }

    @Test func httpTakesProxiesAndCookies() async throws {
        StubProtocol.route("cookies.test") { request in
            (200, ["Set-Cookie": "qrsig=abc; Path=/; Domain=cookies.test", "Content-Type": "text/plain"], Data((request.value(forHTTPHeaderField: "Cookie") ?? "-").utf8))
        }
        let plugin = try Fixture.plugin(hosts: ["cookies.test"], """
        test: {
          async plain() { const r = await starry.http.get('https://cookies.test/a', { cookies: false, headers: { Cookie: 'mine=1' } }); return { sent: r.body, set: r.cookies.qrsig }; },
          async proxied() { return (await starry.http.get('https://cookies.test/b', { proxy: 'socks5://127.0.0.1:1080', cookies: false })).status; },
          async badProxy() { return (await starry.http.get('https://cookies.test/c', { proxy: 'nope' })).status; },
        },
        """)
        let plain: AnyJSON = try await plugin.call("test.plain")
        #expect(plain["sent"] as? String == "mine=1")
        #expect(plain["set"] as? String == "abc")
        let status: Double = try await plugin.call("test.proxied")
        #expect(status == 200)
        await #expect {
            let _: Double = try await plugin.call("test.badProxy")
        } throws: { error in
            guard case .script(_, let code, let message) = error as? PluginError else { return false }
            return code == "badRequest" && message.contains("代理地址")
        }
    }
}

@Suite struct PluginCallTests {
    @Test func errorsBecomeTheAppsOwn() async throws {
        let plugin = try Fixture.plugin("""
        test: {
          vip() { throw starry.error('vipRequired', '需要会员'); },
          region() { return Promise.reject(starry.error('unavailableInRegion')); },
          plain() { throw new Error('出错了'); },
          thrown() { throw 'a string'; },
          missing: 1,
          async slow() { await new Promise(() => {}); },
          bad() { return { songs: [{ title: 1 }] }; },
        },
        """, timeout: 0.5)
        await #expect(throws: PlaybackError.vipRequired) { let _: AnyJSON = try await plugin.call("test.vip") }
        await #expect(throws: PlaybackError.unavailableInRegion) { let _: AnyJSON = try await plugin.call("test.region") }
        await #expect(throws: PluginError.script(plugin: "Fixture", code: nil, message: "出错了")) { let _: AnyJSON = try await plugin.call("test.plain") }
        await #expect(throws: PluginError.script(plugin: "Fixture", code: nil, message: "a string")) { let _: AnyJSON = try await plugin.call("test.thrown") }
        await #expect(throws: SourceError.notImplemented("插件没有实现 test.missing")) { let _: AnyJSON = try await plugin.call("test.missing") }
        await #expect(throws: PluginError.timeout(plugin: "Fixture", path: "test.slow")) { let _: AnyJSON = try await plugin.call("test.slow") }
        await #expect {
            let _: WireSearchPage = try await plugin.call("test.bad")
        } throws: { error in
            guard case .badResult(_, let path, let detail) = error as? PluginError else { return false }
            return path == "test.bad" && detail.contains("songs")
        }
    }

    @Test func callsRunConcurrently() async throws {
        let plugin = try Fixture.plugin("""
        test: { async wait(ms, value) { await new Promise((resolve) => setTimeout(resolve, ms)); return value; } },
        """)
        let start = Date()
        async let a: Int = plugin.call("test.wait", 200, 1)
        async let b: Int = plugin.call("test.wait", 200, 2)
        let results = try await [a, b]
        #expect(results == [1, 2])
        #expect(Date().timeIntervalSince(start) < 0.39)
    }

    @Test func cancellationEndsTheWait() async throws {
        let plugin = try Fixture.plugin("test: { async never() { await new Promise(() => {}); } },")
        let task = Task { () -> Int in try await plugin.call("test.never") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func runawayLoopsAreStopped() async throws {
        let plugin = try Fixture.plugin("test: { spin() { const items = []; for (;;) { items.push({}); if (items.length > 1000) items.length = 0; } }, ok() { return 1; } },", timeout: 20)
        let start = Date()
        await #expect(throws: PluginError.self) { let _: AnyJSON = try await plugin.call("test.spin") }
        #expect(Date().timeIntervalSince(start) < 3)
        let ok: Int = try await plugin.call("test.ok")
        #expect(ok == 1)
    }
}
