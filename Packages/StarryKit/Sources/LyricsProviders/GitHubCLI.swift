import Foundation

/// GitHub REST calls made as one account. `path` is relative to the API root, such as `repos/owner/name/pulls`.
public protocol GitHubAPI: Sendable {
    func send(_ method: String, _ path: String, body: Data?) async throws -> Data
}

public enum GitHubError: Error, Sendable, Equatable, LocalizedError {
    case cliMissing
    case signedOut
    case status(Int, String)
    case failed(String)
    case malformedResponse
    case forkUnavailable

    public var errorDescription: String? {
        switch self {
        case .cliMissing: "没有找到 GitHub CLI（gh）。可以用 Homebrew 安装：brew install gh，然后运行 gh auth login。"
        case .signedOut: "gh 还没有登录 GitHub。在终端运行 gh auth login，然后重试。"
        case let .status(code, message): "GitHub 返回 \(code)：\(message)"
        case .failed(let message): message
        case .malformedResponse: "GitHub 的响应无法识别。"
        case .forkUnavailable: "fork 的仓库迟迟没有准备好，请稍后重试。"
        }
    }
}

/// Sends requests through the signed-in GitHub CLI, so the app never handles the token.
public struct GitHubCLI: GitHubAPI {
    private let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Apps opened from the Finder don't get the shell's PATH, so common install locations are checked too.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.nix-profile/bin", "/run/current-system/sw/bin", "/opt/local/bin", "/usr/bin"]
        for directory in directories where !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public func send(_ method: String, _ path: String, body: Data?) async throws -> Data {
        var arguments = ["api", "--method", method, path,
                         "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28"]
        var input: URL?
        if let body {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("starry-gh-\(UUID().uuidString).json")
            try body.write(to: url, options: .atomic)
            input = url
            arguments += ["--input", url.path]
        }
        defer { if let input { try? FileManager.default.removeItem(at: input) } }
        let outcome = try await Self.run(executable, arguments: arguments)
        guard outcome.status == 0 else { throw Self.failure(status: outcome.status, output: outcome.output, error: outcome.error) }
        return outcome.output
    }

    /// `gh api` prints the response body on stdout and `gh: Message (HTTP 404)` on stderr; exit code 4 means it isn't signed in.
    private static func failure(status: Int32, output: Data, error: Data) -> GitHubError {
        if status == 4 { return .signedOut }
        let message = String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code = httpStatus(in: message) else {
            return .failed(message.isEmpty ? "gh 退出码 \(status)" : message)
        }
        if code == 401 { return .signedOut }
        return .status(code, detail(of: output) ?? message)
    }

    private static func httpStatus(in message: String) -> Int? {
        guard let range = message.range(of: "(HTTP ", options: .backwards) else { return nil }
        return Int(message[range.upperBound...].prefix(3))
    }

    private static func detail(of output: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let message = object["message"] as? String else { return nil }
        let reasons = (object["errors"] as? [Any] ?? []).compactMap { item -> String? in
            if let text = item as? String { return text }
            return (item as? [String: Any])?["message"] as? String
        }
        return ([message] + reasons).joined(separator: "：")
    }

    private struct Outcome: Sendable {
        var status: Int32
        var output: Data
        var error: Data
    }

    private static func run(_ executable: URL, arguments: [String]) async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(executable, arguments: arguments) })
            }
        }
    }

    private static func runBlocking(_ executable: URL, arguments: [String]) throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_SPINNER_DISABLED": "1", "NO_COLOR": "1"] {
            environment[key] = value
        }
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain stderr alongside stdout, so neither pipe fills up and stalls gh.
        let errors = PipeReader(error.fileHandleForReading)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errors.read()
            group.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus, output: data, error: errors.data)
    }
}

private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private(set) var data = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func read() { data = handle.readDataToEndOfFile() }
}
