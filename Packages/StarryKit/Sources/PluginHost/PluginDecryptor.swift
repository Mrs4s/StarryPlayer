import Foundation
import JavaScriptCore
import os
import StarryCore

/// Run stream decryption synchronously in a separate VM so network work on the
/// plugin queue cannot block audio downloads. Each chunk is copied and modified in place.
final class PluginDecryptor: StreamDecryptor, @unchecked Sendable {
    private static let logger = Logger(subsystem: "moe.mrs4s.starry-player", category: "plugin")

    private let script: String
    private let file: URL
    private let info: String
    private let parameters: String
    private let executionLimit: TimeInterval
    private let lock = NSLock()
    private var worker: Worker?
    private var failed = false

    init(script: String, file: URL, info: String, parameters: String, executionLimit: TimeInterval) {
        self.script = script
        self.file = file
        self.info = info
        self.parameters = parameters
        self.executionLimit = executionLimit
    }

    /// Leaves `bytes` as they are when the worker cannot be made or the function throws.
    func decrypt(_ bytes: UnsafeMutableRawBufferPointer, at offset: Int64) {
        guard bytes.count > 0, bytes.baseAddress != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        if worker == nil, !failed {
            do {
                worker = try Worker(script: script, file: file, info: info, parameters: parameters, executionLimit: executionLimit)
            } catch {
                failed = true
                Self.logger.error("\(self.file.lastPathComponent, privacy: .public) decryptor: \((error as? LocalizedError)?.errorDescription ?? "\(error)", privacy: .public)")
            }
        }
        guard let worker else { return }
        if let message = worker.run(bytes, at: offset), !failed {
            failed = true
            Self.logger.error("\(self.file.lastPathComponent, privacy: .public) decryptor threw: \(message, privacy: .public)")
        }
    }
}

private final class Worker {
    private let context: JSContext
    private let function: JSValue

    init(script: String, file: URL, info: String, parameters: String, executionLimit: TimeInterval) throws {
        guard let machine = JSVirtualMachine(), let context = JSContext(virtualMachine: machine) else { throw PluginError.load("无法创建 JavaScript 环境") }
        let thrown = ThrownBox()
        context.exceptionHandler = { _, exception in thrown.value = exception }
        ExecutionLimit.apply(to: context, seconds: executionLimit)
        HostFunctions.install(in: context, runtime: nil)
        func check(_ step: String) throws {
            guard let exception = thrown.value else { return }
            thrown.value = nil
            throw PluginError.load("\(step)：\(exception.forProperty("message")?.toString() ?? exception.toString() ?? "")")
        }
        let hooks = context.evaluateScript(try PluginRuntime.prelude(), withSourceURL: URL(string: "starry://host/prelude.js"))
        try check("prelude.js")
        hooks?.forProperty("setInfo").call(withArguments: [info])
        try check("setInfo")
        context.evaluateScript(script, withSourceURL: file)
        try check(file.lastPathComponent)
        let function = hooks?.forProperty("makeDecryptor").call(withArguments: [parameters])
        try check("source.decryptor")
        guard let function, function.isObject, JSObjectIsFunction(context.jsGlobalContextRef, function.jsValueRef) else {
            throw PluginError.load("source.decryptor 没有返回函数")
        }
        self.context = context
        self.function = function
    }

    func run(_ bytes: UnsafeMutableRawBufferPointer, at offset: Int64) -> String? {
        let ref = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let array = JSObjectMakeTypedArray(ref, kJSTypedArrayTypeUint8Array, bytes.count, &exception),
              let input = JSObjectGetTypedArrayBytesPtr(ref, array, &exception) else { return "无法分配 \(bytes.count) 字节" }
        memcpy(input, bytes.baseAddress!, bytes.count)
        let arguments: [JSValueRef?] = [array, JSValueMakeNumber(ref, Double(offset))]
        _ = arguments.withUnsafeBufferPointer { JSObjectCallAsFunction(ref, JSValueToObject(ref, function.jsValueRef, nil), nil, 2, $0.baseAddress, &exception) }
        if let exception {
            let value = JSValue(jsValueRef: exception, in: context)
            return value?.forProperty("message")?.toString() ?? value?.toString() ?? "?"
        }
        // The pointer is only good until the next call into JavaScriptCore.
        guard let output = JSObjectGetTypedArrayBytesPtr(ref, array, &exception) else { return "数据丢失" }
        memcpy(bytes.baseAddress!, output, bytes.count)
        return nil
    }
}

private final class ThrownBox: @unchecked Sendable {
    var value: JSValue?
}
