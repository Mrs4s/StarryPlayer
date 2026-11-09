import Foundation
import LyricsCore

/// Opens a pull request that adds one lyrics file to the AMLL TTML DB from the account's fork.
public struct AMLLPullRequest: Sendable {
    public enum Step: Sendable, Equatable {
        case forking, branching, uploading, opening
    }

    public struct Submission: Sendable {
        public var ttml: String
        public var title: String
        public var metadata: [(key: String, value: String)]
        public var remarks: String
        public var date: Date
        public var token: String

        public init(ttml: String, title: String, metadata: [(key: String, value: String)], remarks: String,
                    date: Date = Date(), token: String = AMLLSubmission.makeToken()) {
            self.ttml = ttml
            self.title = title
            self.metadata = metadata
            self.remarks = remarks
            self.date = date
            self.token = token
        }
    }

    public struct Result: Sendable, Equatable {
        public var number: Int
        public var url: URL
        /// `owner/name` of the fork holding the branch.
        public var fork: String
        public var branch: String
        public var path: String
    }

    private let api: any GitHubAPI
    private let sleep: @Sendable (Duration) async throws -> Void
    private static let upstream = "repos/\(AMLLSubmission.owner)/\(AMLLSubmission.repository)"

    public init(api: any GitHubAPI, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.api = api
        self.sleep = sleep
    }

    public func account() async throws -> AMLLSubmission.Author {
        try await call("GET", "user")
    }

    public func submit(_ submission: Submission, as author: AMLLSubmission.Author,
                       progress: @escaping @Sendable (Step) async -> Void = { _ in }) async throws -> Result {
        await progress(.forking)
        // Returns the existing fork when there is one, whatever its name.
        let fork: Repository = try await call("POST", "\(Self.upstream)/forks", body: ForkRequest(defaultBranchOnly: true))
        let base: Reference = try await call("GET", "\(Self.upstream)/git/ref/heads/\(AMLLSubmission.baseBranch)")

        await progress(.branching)
        let branch = "starry/\(submission.token)"
        try await createBranch(branch, at: base.object.sha, in: fork.fullName)

        await progress(.uploading)
        let fileName = AMLLSubmission.rawFileName(date: submission.date, authorID: author.id, token: submission.token)
        let path = "\(AMLLSubmission.rawDirectory)/\(fileName)"
        let _: Ignored = try await call("PUT", "repos/\(fork.fullName)/contents/\(path)",
                                        body: ContentRequest(message: "提交歌曲歌词 \(fileName)", content: Data(submission.ttml.utf8).base64EncodedString(), branch: branch))

        await progress(.opening)
        let pull: Pull = try await call("POST", "\(Self.upstream)/pulls", body: PullRequestRequest(
            title: submission.title, head: "\(fork.owner.login):\(branch)", base: AMLLSubmission.baseBranch,
            body: AMLLSubmission.pullRequestBody(number: nil, author: author, metadata: submission.metadata, remarks: submission.remarks),
            maintainerCanModify: true))
        // The number only exists now; the pull request is open either way, so a failed edit isn't an error.
        let numbered = AMLLSubmission.pullRequestBody(number: pull.number, author: author, metadata: submission.metadata, remarks: submission.remarks)
        _ = try? await call("PATCH", "\(Self.upstream)/pulls/\(pull.number)", body: BodyUpdate(body: numbered)) as Ignored
        return Result(number: pull.number, url: pull.htmlUrl, fork: fork.fullName, branch: branch, path: path)
    }

    /// A new fork is created in the background and answers 404 or 409 until it's ready. An older fork may
    /// lack the upstream commit, which fails with 422 until its branch is synced.
    private func createBranch(_ branch: String, at sha: String, in fork: String) async throws {
        var synced = false
        for attempt in 0..<12 {
            do {
                let _: Ignored = try await call("POST", "repos/\(fork)/git/refs", body: ReferenceRequest(ref: "refs/heads/\(branch)", sha: sha))
                return
            } catch GitHubError.status(let code, _) where code == 404 || code == 409 {
                guard attempt < 11 else { break }
                try await sleep(.seconds(min(2 + attempt, 6)))
            } catch GitHubError.status(422, _) where !synced {
                synced = true
                _ = try? await call("POST", "repos/\(fork)/merge-upstream", body: MergeUpstreamRequest(branch: AMLLSubmission.baseBranch)) as Ignored
            }
        }
        throw GitHubError.forkUnavailable
    }

    // MARK: Requests

    private func call<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        try decode(try await api.send(method, path, body: nil))
    }

    private func call<Response: Decodable>(_ method: String, _ path: String, body: some Encodable) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try decode(try await api.send(method, path, body: try encoder.encode(body)))
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(Response.self, from: data) } catch { throw GitHubError.malformedResponse }
    }

    private struct Repository: Decodable {
        struct Owner: Decodable { var login: String }
        var fullName: String
        var owner: Owner
    }

    private struct Reference: Decodable {
        struct Object: Decodable { var sha: String }
        var object: Object
    }

    private struct Pull: Decodable {
        var number: Int
        var htmlUrl: URL
    }

    private struct Ignored: Decodable {}

    private struct ForkRequest: Encodable { var defaultBranchOnly: Bool }
    private struct ReferenceRequest: Encodable { var ref: String; var sha: String }
    private struct ContentRequest: Encodable { var message: String; var content: String; var branch: String }
    private struct MergeUpstreamRequest: Encodable { var branch: String }
    private struct BodyUpdate: Encodable { var body: String }

    private struct PullRequestRequest: Encodable {
        var title: String
        var head: String
        var base: String
        var body: String
        var maintainerCanModify: Bool
    }
}
