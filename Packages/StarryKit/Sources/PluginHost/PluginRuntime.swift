import Foundation
import JavaScriptCore
import os

/// The VM and JSContext must only be accessed on `queue`.
final class PluginRuntime: @unchecked Sendable {
    struct Options: @unchecked Sendable {
        var name: String
        var inspectable = false
        var callTimeout: TimeInterval = 30
        /// CPU time one entry into JavaScript may take before it is stopped (best effort: a
        /// JIT-compiled loop that does nothing but arithmetic is not stopped).
        var executionLimit: TimeInterval = 5
        var protocolClasses: [AnyClass] = []
    }

    struct ScriptFailure: Error, Decodable {
        var code: String?
        var message: String
        var stack: String?
    }

    enum Failure: Error {
        case timeout
        case unavailable
    }

    let queue: DispatchQueue
    let http: PluginHTTP
    let logger = Logger(subsystem: "moe.mrs4s.starry-player", category: "plugin")
    private let callTimeout: TimeInterval
    private let nameLock: OSAllocatedUnfairLock<String>
    let webPages = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)

    // Queue-confined.
    private var context: JSContext!
    private var hooks: JSValue!
    private var exception: JSValue?
    private(set) var storage = PluginStorage(file: nil)

    init(options: Options) throws {
        nameLock = OSAllocatedUnfairLock(initialState: options.name)
        queue = DispatchQueue(label: "moe.mrs4s.starry-player.plugin", qos: .userInitiated)
        http = PluginHTTP(protocolClasses: options.protocolClasses)
        callTimeout = options.callTimeout
        try queue.sync { try setUp(options) }
    }

    var name: String { nameLock.withLock { $0 } }

    private func setUp(_ options: Options) throws {
        guard let machine = JSVirtualMachine(), let context = JSContext(virtualMachine: machine) else { throw PluginError.load("无法创建 JavaScript 环境") }
        self.context = context
        context.name = "插件：\(options.name)"
        context.isInspectable = options.inspectable
        context.exceptionHandler = { [weak self] _, exception in self?.exception = exception }
        ExecutionLimit.apply(to: context, seconds: options.executionLimit)
        HostFunctions.install(in: context, runtime: self)
        let hooks = context.evaluateScript(try Self.prelude(), withSourceURL: URL(string: "starry://host/prelude.js"))
        if let failure = takeException() { throw PluginError.load("prelude.js：\(failure.message)") }
        guard let hooks, hooks.isObject else { throw PluginError.load("prelude.js 没有返回接口") }
        self.hooks = hooks
    }

    static func prelude() throws -> String {
        guard let url = Bundle.module.url(forResource: "prelude", withExtension: "js"), let prelude = try? String(contentsOf: url, encoding: .utf8) else {
            throw PluginError.load("缺少 prelude.js")
        }
        return prelude
    }

    func load(script: String, url: URL, info: String) throws -> String {
        try queue.sync {
            try setInfo(info)
            context.evaluateScript(script, withSourceURL: url)
            if let failure = takeException() { throw PluginError.load("\(url.lastPathComponent)：\(failure.message)") }
            let description = hooks.forProperty("describe").call(withArguments: [])
            if let failure = takeException() { throw PluginError.load(failure.message) }
            guard let description, description.isString, let text = description.toString() else { throw PluginError.load("读不到插件导出的对象") }
            return text
        }
    }

    func configure(name: String, hosts: [String], storageFile: URL?, info: String) throws {
        nameLock.withLock { $0 = name }
        http.allow(hosts)
        try queue.sync {
            context.name = "插件：\(name)"
            storage = PluginStorage(file: storageFile)
            try setInfo(info)
        }
    }

    private func setInfo(_ info: String) throws {
        hooks.forProperty("setInfo").call(withArguments: [info])
        if let failure = takeException() { throw PluginError.load(failure.message) }
    }

    /// Calls the plugin function at `path` (`source.search`) with a JSON array of arguments and
    /// returns its result as JSON. Throws `ScriptFailure` when the plugin throws and
    /// `Failure.timeout` after `timeout` (the options' `callTimeout` when nil).
    func invoke(_ path: String, argumentsJSON: String, timeout: TimeInterval? = nil) async throws -> String {
        let once = Once<String>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.attach(continuation)
                queue.async { self.start(path, argumentsJSON, once) }
                // Not on `queue`: a plugin stuck in a loop must still time out.
                DispatchQueue.global().asyncAfter(deadline: .now() + (timeout ?? callTimeout)) { once.finish(.failure(Failure.timeout)) }
            }
        } onCancel: {
            once.finish(.failure(CancellationError()))
        }
    }

    private func start(_ path: String, _ argumentsJSON: String, _ once: Once<String>) {
        guard let invoke = hooks?.forProperty("invoke") else { return once.finish(.failure(Failure.unavailable)) }
        let fulfil: @convention(block) (JSValue) -> Void = { value in
            once.finish(.success(value.toString() ?? "null"))
        }
        let reject: @convention(block) (JSValue) -> Void = { value in
            let text = value.toString() ?? ""
            let failure = (try? JSONDecoder().decode(ScriptFailure.self, from: Data(text.utf8))) ?? ScriptFailure(message: text)
            once.finish(.failure(failure))
        }
        let promise = invoke.call(withArguments: [path, argumentsJSON])
        if let failure = takeException() { return once.finish(.failure(failure)) }
        promise?.invokeMethod("then", withArguments: [JSValue(object: fulfil, in: context) as Any, JSValue(object: reject, in: context) as Any])
        if let failure = takeException() { once.finish(.failure(failure)) }
    }

    func setSettings(_ json: String, notify: Bool) {
        queue.async {
            self.hooks.forProperty("setSettings").call(withArguments: [json, notify])
            if let failure = self.takeException() { self.log(.error, "设置没有生效：\(failure.message)") }
        }
    }

    func schedule(timer id: Int, after milliseconds: Double) {
        queue.asyncAfter(deadline: .now() + milliseconds / 1000) { [weak self] in
            guard let self else { return }
            hooks.forProperty("fireTimer").call(withArguments: [id])
            if let failure = takeException() { log(.error, "定时器出错：\(failure.message)") }
        }
    }

    func log(_ level: OSLogType, _ message: String) {
        logger.log(level: level, "[\(self.name, privacy: .public)] \(message, privacy: .public)")
    }

    private func takeException() -> ScriptFailure? {
        guard let exception else { return nil }
        self.exception = nil
        let message = exception.forProperty("message").flatMap { $0.isUndefined ? nil : $0.toString() } ?? exception.toString() ?? "未知错误"
        let line = exception.forProperty("line").flatMap { $0.isUndefined ? nil : $0.toString() }
        let stack = exception.forProperty("stack").flatMap { $0.isUndefined ? nil : $0.toString() }
        log(.error, "\(message)\(line.map { "（第 \($0) 行）" } ?? "")\(stack.map { "\n\($0)" } ?? "")")
        let code = exception.forProperty("code").flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() }
        return ScriptFailure(code: code, message: message, stack: stack)
    }
}

final class Once<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var result: Result<Value, Error>?
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        let pending: Result<Value, Error>? = state.withLock { state in
            if let result = state.result {
                state.result = nil
                return result
            }
            state.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func finish(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            guard let continuation = state.continuation else {
                state.result = result
                return nil
            }
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

/// `JSContextGroupSetExecutionTimeLimit`, a JavaScriptCore function without a public header.
enum ExecutionLimit {
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void

    private static let setLimit: SetLimit? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    static func apply(to context: JSContext, seconds: TimeInterval) {
        guard seconds > 0, let setLimit else { return }
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), seconds, nil, nil)
    }
}
