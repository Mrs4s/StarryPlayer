import Foundation
import JavaScriptCore
import os

/// Native plugin API, running on the plugin queue with weak runtime references.
/// Decryption workers have no runtime, network, storage or timers.
enum HostFunctions {
    private static let workerLogger = Logger(subsystem: "moe.mrs4s.starry-player", category: "plugin")

    static func install(in context: JSContext, runtime: PluginRuntime?) {
        guard let native = JSValue(newObjectIn: context) else { return }
        func define(_ name: String, _ block: Any) {
            native.setValue(block, forProperty: name)
        }

        let log: @convention(block) (JSValue, JSValue) -> Void = { [weak runtime] level, message in
            let type: OSLogType = switch level.toString() {
            case "debug": .debug
            case "warning", "error": .error
            default: .info
            }
            if let runtime {
                runtime.log(type, message.toString() ?? "")
            } else {
                workerLogger.log(level: type, "[worker] \(message.toString() ?? "", privacy: .public)")
            }
        }
        define("log", log)

        let schedule: @convention(block) (JSValue, JSValue) -> Void = { [weak runtime] id, milliseconds in
            runtime?.schedule(timer: Int(id.toInt32()), after: max(0, milliseconds.toDouble()))
        }
        define("schedule", schedule)

        let http: @convention(block) (JSValue) -> JSValue = { [weak runtime] options in
            guard let runtime else { return fail("这里不能联网") }
            let request: PluginHTTP.Request
            do {
                request = try PluginHTTP.Request(options)
            } catch {
                return fail(error)
            }
            return JSValue(newPromiseIn: JSContext.current()) { resolve, reject in
                guard let resolve, let reject else { return }
                let callbacks = PromiseCallbacks(resolve: resolve, reject: reject)
                Task {
                    do {
                        let response = try await runtime.http.perform(request)
                        runtime.queue.async { callbacks.resolve(response.value(in: callbacks.context, bytes: request.wantsBytes)) }
                    } catch {
                        runtime.queue.async { callbacks.reject(error) }
                    }
                }
            }
        }
        define("http", http)

        let utf8Encode: @convention(block) (JSValue) -> JSValue = { text in
            bytes(Data((text.toString() ?? "").utf8))
        }
        define("utf8Encode", utf8Encode)

        let supportsEncoding: @convention(block) (JSValue) -> Bool = { label in
            TextEncodings.encoding(label.toString() ?? "") != nil
        }
        define("supportsEncoding", supportsEncoding)

        let decodeText: @convention(block) (JSValue, JSValue) -> JSValue = { value, label in
            guard let data = data(value) else { return fail("decode 需要 Uint8Array") }
            guard let encoding = TextEncodings.encoding(label.toString() ?? "") else { return fail("不支持的编码：\(label.toString() ?? "")") }
            guard let text = TextEncodings.decode(data, encoding) else { return fail("无法按 \(label.toString() ?? "") 解码") }
            return JSValue(object: text, in: JSContext.current())
        }
        define("decodeText", decodeText)

        let base64Encode: @convention(block) (JSValue) -> JSValue = { value in
            guard let data = data(value) else { return fail("base64 需要 Uint8Array") }
            return JSValue(object: data.base64EncodedString(), in: JSContext.current())
        }
        define("base64Encode", base64Encode)

        let base64Decode: @convention(block) (JSValue) -> JSValue = { value in
            var text = (value.toString() ?? "").filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            text += String(repeating: "=", count: (4 - text.count % 4) % 4)
            guard let data = Data(base64Encoded: text) else { return fail("不是 base64") }
            return bytes(data)
        }
        define("base64Decode", base64Decode)

        let hash: @convention(block) (JSValue, JSValue) -> JSValue = { algorithm, value in
            guard let data = data(value) else { return fail("hash 需要数据") }
            do {
                return bytes(try PluginCrypto.hash(algorithm.toString() ?? "", data))
            } catch {
                return fail(error)
            }
        }
        define("hash", hash)

        let hmac: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = { algorithm, key, value in
            guard let key = data(key), let data = data(value) else { return fail("hmac 需要 key 和数据") }
            do {
                return bytes(try PluginCrypto.hmac(algorithm.toString() ?? "", key: key, data))
            } catch {
                return fail(error)
            }
        }
        define("hmac", hmac)

        let cipher: @convention(block) (JSValue) -> JSValue = { options in
            guard let key = data(options.forProperty("key")), let input = data(options.forProperty("data")) else { return fail("需要 key 和 data") }
            let request = PluginCrypto.Cipher(
                algorithm: options.forProperty("algorithm").toString() ?? "",
                mode: options.forProperty("mode").toString() ?? "",
                decrypt: options.forProperty("decrypt").toBool(),
                key: key,
                iv: data(options.forProperty("iv")),
                aad: data(options.forProperty("aad")),
                padding: options.forProperty("padding").toBool()
            )
            do {
                return bytes(try PluginCrypto.run(request, input))
            } catch {
                return fail(error)
            }
        }
        define("cipher", cipher)

        let rsaEncrypt: @convention(block) (JSValue) -> JSValue = { options in
            guard let input = data(options.forProperty("data")) else { return fail("rsa.encrypt 需要 data") }
            do {
                let key = options.forProperty("publicKey").toString() ?? ""
                return bytes(try PluginCrypto.rsaEncrypt(input, publicKey: key, padding: options.forProperty("padding").toString() ?? "pkcs1"))
            } catch {
                return fail(error)
            }
        }
        define("rsaEncrypt", rsaEncrypt)

        let randomBytes: @convention(block) (JSValue) -> JSValue = { count in
            bytes(PluginCrypto.randomBytes(Int(min(max(count.toInt32(), 0), 1 << 20))))
        }
        define("randomBytes", randomBytes)

        let inflate: @convention(block) (JSValue) -> JSValue = { value in
            guard let data = data(value) else { return fail("inflate 需要 Uint8Array") }
            do {
                return bytes(try PluginZlib.inflate(data))
            } catch {
                return fail(error)
            }
        }
        define("inflate", inflate)

        let deflate: @convention(block) (JSValue, JSValue) -> JSValue = { value, format in
            guard let data = data(value) else { return fail("deflate 需要 Uint8Array") }
            do {
                return bytes(try PluginZlib.deflate(data, format: format.toString() ?? "zlib"))
            } catch {
                return fail(error)
            }
        }
        define("deflate", deflate)

        let parseURL: @convention(block) (JSValue, JSValue) -> JSValue = { value, base in
            let context = JSContext.current()!
            let baseURL = base.isUndefined ? nil : URL(string: base.toString() ?? "")
            guard let text = value.toString(), let url = URL(string: text, relativeTo: baseURL)?.absoluteURL,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: true), let scheme = components.scheme else {
                return JSValue(nullIn: context)
            }
            let path = components.percentEncodedPath
            let parts: [String: String] = [
                "protocol": "\(scheme.lowercased()):",
                "username": components.percentEncodedUser ?? "",
                "password": components.percentEncodedPassword ?? "",
                "hostname": components.percentEncodedHost?.lowercased() ?? "",
                "port": components.port.map(String.init) ?? "",
                "pathname": path.isEmpty && components.host != nil ? "/" : path,
                "search": components.percentEncodedQuery.map { $0.isEmpty ? "" : "?\($0)" } ?? "",
                "hash": components.percentEncodedFragment.map { $0.isEmpty ? "" : "#\($0)" } ?? "",
            ]
            return JSValue(object: parts, in: context)
        }
        define("parseURL", parseURL)

        let storageGet: @convention(block) (JSValue) -> JSValue = { [weak runtime] key in
            guard let value = runtime?.storage.value(for: key.toString() ?? "") else { return undefined() }
            return JSValue(object: value, in: JSContext.current())
        }
        define("storageGet", storageGet)

        let storageSet: @convention(block) (JSValue, JSValue) -> Void = { [weak runtime] key, value in
            guard let runtime else { return }
            runtime.storage.set(value.toString(), for: key.toString() ?? "", saveOn: runtime.queue)
        }
        define("storageSet", storageSet)

        let storageRemove: @convention(block) (JSValue) -> Void = { [weak runtime] key in
            guard let runtime else { return }
            runtime.storage.set(nil, for: key.toString() ?? "", saveOn: runtime.queue)
        }
        define("storageRemove", storageRemove)

        let storageKeys: @convention(block) () -> JSValue = { [weak runtime] in
            JSValue(object: runtime?.storage.keys ?? [], in: JSContext.current())
        }
        define("storageKeys", storageKeys)

        let storageClear: @convention(block) () -> Void = { [weak runtime] in
            guard let runtime else { return }
            runtime.storage.clear(saveOn: runtime.queue)
        }
        define("storageClear", storageClear)

        let setWebPages: @convention(block) (JSValue) -> Void = { [weak runtime] json in
            guard let runtime else { return }
            let pages = json.isString ? (try? JSONDecoder().decode([String: String].self, from: Data((json.toString() ?? "").utf8))) : nil
            runtime.webPages.withLock { $0 = pages }
        }
        define("setWebPages", setWebPages)

        context.setObject(native, forKeyedSubscript: "__starryNative" as NSString)
    }

    private static func undefined() -> JSValue {
        JSValue(undefinedIn: JSContext.current())
    }

    private static func fail(_ message: String) -> JSValue {
        let context = JSContext.current()!
        context.exception = JSValue(newErrorFromMessage: message, in: context)
        return JSValue(undefinedIn: context)
    }

    private static func fail(_ error: any Error) -> JSValue {
        let result = fail((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        if let failure = error as? PluginHTTP.Failure { JSContext.current()?.exception?.setValue(failure.code, forProperty: "code") }
        return result
    }

    /// The bytes of a `Uint8Array` (or any typed array or `ArrayBuffer`), or of a string as UTF-8.
    static func data(_ value: JSValue?) -> Data? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isString { return value.toString().map { Data($0.utf8) } }
        let context = value.context.jsGlobalContextRef
        let ref = value.jsValueRef
        var exception: JSValueRef?
        let type = JSValueGetTypedArrayType(context, ref, &exception)
        guard type != kJSTypedArrayTypeNone, let object = JSValueToObject(context, ref, &exception) else { return nil }
        if type == kJSTypedArrayTypeArrayBuffer {
            let length = JSObjectGetArrayBufferByteLength(context, object, &exception)
            guard length > 0 else { return Data() }
            guard let pointer = JSObjectGetArrayBufferBytesPtr(context, object, &exception) else { return nil }
            return Data(bytes: pointer, count: length)
        }
        let length = JSObjectGetTypedArrayByteLength(context, object, &exception)
        guard length > 0 else { return Data() }
        guard let pointer = JSObjectGetTypedArrayBytesPtr(context, object, &exception) else { return nil }
        let offset = JSObjectGetTypedArrayByteOffset(context, object, &exception)
        return Data(bytes: pointer.advanced(by: offset), count: length)
    }

    static func bytes(_ data: Data, in context: JSContext = JSContext.current()) -> JSValue {
        let count = data.count
        let buffer = malloc(max(count, 1))!
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: count)
        var exception: JSValueRef?
        let array = JSObjectMakeTypedArrayWithBytesNoCopy(context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, buffer, count, { bytes, _ in free(bytes) }, nil, &exception)
        return JSValue(jsValueRef: array, in: context)
    }
}

/// A promise's resolve and reject, carried to the plugin's queue when a host call finishes.
private final class PromiseCallbacks: @unchecked Sendable {
    private let resolveFunction: JSValue
    private let rejectFunction: JSValue

    init(resolve: JSValue, reject: JSValue) {
        resolveFunction = resolve
        rejectFunction = reject
    }

    var context: JSContext { resolveFunction.context }

    func resolve(_ value: JSValue) {
        resolveFunction.call(withArguments: [value])
    }

    func reject(_ error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let value = JSValue(newErrorFromMessage: message, in: context)
        value?.setValue((error as? PluginHTTP.Failure)?.code ?? "network", forProperty: "code")
        rejectFunction.call(withArguments: [value as Any])
    }
}

enum TextEncodings {
    static func encoding(_ label: String) -> String.Encoding? {
        switch label.trimmingCharacters(in: .whitespaces).lowercased() {
        case "utf-8", "utf8", "unicode-1-1-utf-8": return .utf8
        case "utf-16le", "utf-16": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        case "latin1", "iso-8859-1", "us-ascii", "ascii", "windows-1252": return .isoLatin1
        case "gbk", "gb2312", "gb18030", "x-gbk": return cf(.GB_18030_2000)
        case "big5", "big5-hkscs": return cf(.big5_HKSCS_1999)
        case "shift_jis", "shift-jis", "sjis": return .shiftJIS
        case "euc-jp": return .japaneseEUC
        case "euc-kr": return cf(.EUC_KR)
        default: return nil
        }
    }

    /// UTF-8 with bad sequences replaced (as `TextDecoder` does); the others strictly.
    static func decode(_ data: Data, _ encoding: String.Encoding) -> String? {
        if encoding == .utf8 { return String(decoding: data, as: UTF8.self) }
        return String(data: data, encoding: encoding)
    }

    private static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}
