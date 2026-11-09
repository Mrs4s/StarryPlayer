import Foundation
import LyricsCore
import Testing
@testable import LyricsProviders

private actor FakeGitHub: GitHubAPI {
    struct Call: Sendable {
        var method: String
        var path: String
        var body: Data?

        var route: String { "\(method) \(path)" }

        func json() throws -> [String: Any] {
            let body = try #require(body)
            let object = try JSONSerialization.jsonObject(with: body)
            return try #require(object as? [String: Any])
        }
    }

    private(set) var calls: [Call] = []
    private var responses: [String: [Result<String, GitHubError>]]

    init(_ responses: [String: [Result<String, GitHubError>]]) {
        self.responses = responses
    }

    /// Each route answers its queued responses in order and then keeps repeating the last one.
    func send(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let call = Call(method: method, path: path, body: body)
        calls.append(call)
        guard var queue = responses[call.route], let next = queue.first else { throw GitHubError.status(404, "Not Found") }
        if queue.count > 1 { queue.removeFirst() }
        responses[call.route] = queue
        return Data(try next.get().utf8)
    }
}

private actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

@Suite struct AMLLPullRequestTests {
    private let author = AMLLSubmission.Author(id: 7, login: "alice")
    private let upstream = "repos/amll-dev/amll-ttml-db"

    private var submission: AMLLPullRequest.Submission {
        AMLLPullRequest.Submission(ttml: "<tt>歌词</tt>", title: "[歌词提交] 田馥甄 - 干净的房间",
                                   metadata: [("musicName", "干净的房间"), ("artists", "田馥甄"), ("ncmMusicId", "3439441346")],
                                   remarks: "首次投稿", date: Date(timeIntervalSince1970: 1_793_807_057.396), token: "TOKEN123")
    }

    private func responses(fork: String = "alice/amll-ttml-db-1", refs: [Result<String, GitHubError>]) -> [String: [Result<String, GitHubError>]] {
        [
            "POST \(upstream)/forks": [.success(#"{"full_name":"\#(fork)","owner":{"login":"alice"}}"#)],
            "GET \(upstream)/git/ref/heads/main": [.success(#"{"object":{"sha":"abc123"}}"#)],
            "POST repos/\(fork)/git/refs": refs,
            "PUT repos/\(fork)/contents/raw-lyrics/1793807057396-7-TOKEN123.ttml": [.success("{}")],
            "POST \(upstream)/pulls": [.success(#"{"number":10900,"html_url":"https://github.com/amll-dev/amll-ttml-db/pull/10900"}"#)],
        ]
    }

    @Test func opensAPullRequestFromTheForkOnceItIsReady() async throws {
        var routes = responses(refs: [.failure(.status(404, "Not Found")), .failure(.status(409, "Git Repository is empty.")), .success("{}")])
        routes["PATCH \(upstream)/pulls/10900"] = [.success("{}")]
        let github = FakeGitHub(routes)
        let sleeps = Recorder<Duration>()
        let steps = Recorder<AMLLPullRequest.Step>()
        let client = AMLLPullRequest(api: github) { await sleeps.append($0) }

        let result = try await client.submit(submission, as: author) { await steps.append($0) }

        #expect(result == AMLLPullRequest.Result(number: 10900, url: URL(string: "https://github.com/amll-dev/amll-ttml-db/pull/10900")!,
                                                 fork: "alice/amll-ttml-db-1", branch: "starry/TOKEN123",
                                                 path: "raw-lyrics/1793807057396-7-TOKEN123.ttml"))
        let calls = await github.calls
        #expect(calls.map(\.route) == [
            "POST \(upstream)/forks", "GET \(upstream)/git/ref/heads/main",
            "POST repos/alice/amll-ttml-db-1/git/refs", "POST repos/alice/amll-ttml-db-1/git/refs", "POST repos/alice/amll-ttml-db-1/git/refs",
            "PUT repos/alice/amll-ttml-db-1/contents/raw-lyrics/1793807057396-7-TOKEN123.ttml",
            "POST \(upstream)/pulls", "PATCH \(upstream)/pulls/10900",
        ])
        #expect(await sleeps.values == [.seconds(2), .seconds(3)])
        #expect(await steps.values == [.forking, .branching, .uploading, .opening])

        #expect(try calls[0].json()["default_branch_only"] as? Bool == true)
        let ref = try calls[4].json()
        #expect(ref["ref"] as? String == "refs/heads/starry/TOKEN123")
        #expect(ref["sha"] as? String == "abc123")
        let file = try calls[5].json()
        #expect(file["branch"] as? String == "starry/TOKEN123")
        #expect(file["message"] as? String == "提交歌曲歌词 1793807057396-7-TOKEN123.ttml")
        let encoded = try #require(file["content"] as? String)
        let content = try #require(Data(base64Encoded: encoded))
        #expect(String(decoding: content, as: UTF8.self) == "<tt>歌词</tt>")
        let pull = try calls[6].json()
        #expect(pull["title"] as? String == "[歌词提交] 田馥甄 - 干净的房间")
        #expect(pull["head"] as? String == "alice:starry/TOKEN123")
        #expect(pull["base"] as? String == "main")
        #expect(pull["maintainer_can_modify"] as? Bool == true)
        #expect(pull["body"] as? String == AMLLSubmission.pullRequestBody(number: nil, author: author, metadata: submission.metadata, remarks: "首次投稿"))
        let update = try calls[7].json()
        #expect((update["body"] as? String)?.hasPrefix("### 歌词议题\n#10900\n\n### 歌词作者\n@alice") == true)
    }

    @Test func syncsAnOlderForkMissingTheUpstreamCommit() async throws {
        var routes = responses(fork: "alice/amll-ttml-db", refs: [.failure(.status(422, "Object does not exist")), .success("{}")])
        routes["POST repos/alice/amll-ttml-db/merge-upstream"] = [.success("{}")]
        let github = FakeGitHub(routes)

        // No PATCH response: renumbering the body fails, but the pull request is already open.
        let result = try await AMLLPullRequest(api: github) { _ in }.submit(submission, as: author)

        #expect(result.number == 10900)
        let calls = await github.calls
        #expect(calls.map(\.route).filter { $0.hasPrefix("POST repos/alice/") } == [
            "POST repos/alice/amll-ttml-db/git/refs", "POST repos/alice/amll-ttml-db/merge-upstream", "POST repos/alice/amll-ttml-db/git/refs",
        ])
        #expect(try calls.first { $0.route.hasSuffix("merge-upstream") }?.json()["branch"] as? String == "main")
    }

    @Test func givesUpWhenTheForkNeverAppears() async throws {
        let github = FakeGitHub(responses(refs: [.failure(.status(404, "Not Found"))]))
        let sleeps = Recorder<Duration>()
        let client = AMLLPullRequest(api: github) { await sleeps.append($0) }

        await #expect(throws: GitHubError.forkUnavailable) { try await client.submit(submission, as: author) }
        #expect(await sleeps.values.count == 11)
        #expect(await github.calls.contains { $0.method == "PUT" } == false)
    }

    @Test func otherFailuresStopTheSubmission() async throws {
        let github = FakeGitHub(responses(refs: [.failure(.status(403, "Resource not accessible by integration"))]))
        await #expect(throws: GitHubError.status(403, "Resource not accessible by integration")) {
            try await AMLLPullRequest(api: github) { _ in }.submit(submission, as: author)
        }
    }

    @Test func accountReadsTheSignedInUser() async throws {
        let github = FakeGitHub(["GET user": [.success(#"{"login":"alice","id":7,"name":"Alice"}"#)]])
        #expect(try await AMLLPullRequest(api: github).account() == author)
    }
}
