import AppKit
import Foundation
@testable import FuturaTerm
import Testing

@Suite(.serialized)
@MainActor
struct GitHubAvatarStoreTests {
    /// 1×1 PNG. Dummy login fixtures only — never a live avatar.
    private static let png1x1 = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )

    @Test
    func run_gate_performs_zero_session_tasks() async throws {
        GitHubAvatarURLProtocolStub.reset()
        let hosts = try writeHostsFile()
        defer { try? FileManager.default.removeItem(at: hosts) }
        let session = stubSession()
        let store = makeStore(session: session, hostsFileURL: hosts, isTestRun: { true })
        store.start()
        await store.refresh()
        #expect(GitHubAvatarURLProtocolStub.loadCount.value == 0)
        #expect(GitHubAvatarURLProtocolStub.lastRequest.value == nil)
        #expect(store.image == nil)
        let tasks = await session.allTasks
        #expect(tasks.isEmpty)
    }

    @Test
    func benchmark_gate_performs_zero_session_tasks() async throws {
        GitHubAvatarURLProtocolStub.reset()
        let hosts = try writeHostsFile()
        defer { try? FileManager.default.removeItem(at: hosts) }
        let session = stubSession()
        let store = makeStore(
            session: session,
            hostsFileURL: hosts,
            isBenchmarkEnabled: { true }
        )
        store.start()
        await store.refresh()
        #expect(GitHubAvatarURLProtocolStub.loadCount.value == 0)
        #expect(GitHubAvatarURLProtocolStub.lastRequest.value == nil)
        #expect(store.image == nil)
        let tasks = await session.allTasks
        #expect(tasks.isEmpty)
    }

    @Test
    func stub_200_png_sets_image() async throws {
        GitHubAvatarURLProtocolStub.reset()
        let png = try #require(Self.png1x1)
        GitHubAvatarURLProtocolStub.response.mutate {
            $0 = .init(status: 200, body: png, contentType: "image/png")
        }
        let hosts = try writeHostsFile()
        defer { try? FileManager.default.removeItem(at: hosts) }
        let store = makeStore(hostsFileURL: hosts)
        await store.refresh()
        #expect(store.image != nil)
        #expect(GitHubAvatarURLProtocolStub.loadCount.value == 1)
        let request = try #require(GitHubAvatarURLProtocolStub.lastRequest.value)
        #expect(request.url?.host == "avatars.githubusercontent.com")
        #expect(request.url?.path == "/octocat")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func stub_404_leaves_image_nil() async throws {
        GitHubAvatarURLProtocolStub.reset()
        GitHubAvatarURLProtocolStub.response.mutate {
            $0 = .init(status: 404, body: Data())
        }
        let hosts = try writeHostsFile()
        defer { try? FileManager.default.removeItem(at: hosts) }
        let store = makeStore(hostsFileURL: hosts)
        await store.refresh()
        #expect(store.image == nil)
        #expect(GitHubAvatarURLProtocolStub.loadCount.value == 1)
        let request = try #require(GitHubAvatarURLProtocolStub.lastRequest.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func gh_host_selects_enterprise_png_url() async throws {
        GitHubAvatarURLProtocolStub.reset()
        GitHubAvatarURLProtocolStub.response.mutate {
            $0 = .init(status: 404, body: Data())
        }
        let hosts = FileManager.default.temporaryDirectory
            .appendingPathComponent("gh-hosts-\(UUID().uuidString).yml")
        let yaml = """
        github.com:
            user: octocat
            oauth_token: dummy-oauth-token-never-copy
        git.example.com:
            user: hubot
            oauth_token: dummy-oauth-token-never-copy
        """
        try Data(yaml.utf8).write(to: hosts)
        defer { try? FileManager.default.removeItem(at: hosts) }
        let store = GitHubAvatarStore(
            session: stubSession(),
            hostsFileURL: hosts,
            environment: { ["GH_HOST": "git.example.com"] },
            home: { "/Users/nobody" },
            isBenchmarkEnabled: { false },
            isTestRun: { false }
        )
        await store.refresh()
        #expect(store.image == nil)
        let request = try #require(GitHubAvatarURLProtocolStub.lastRequest.value)
        #expect(request.url?.absoluteString == "https://git.example.com/hubot.png")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func missing_hosts_file_does_not_fetch() async {
        GitHubAvatarURLProtocolStub.reset()
        let missing = URL(fileURLWithPath: "/tmp/futuraterm-missing-gh-hosts-\(UUID().uuidString).yml")
        let store = makeStore(hostsFileURL: missing)
        await store.refresh()
        #expect(store.image == nil)
        #expect(GitHubAvatarURLProtocolStub.loadCount.value == 0)
    }

    private func makeStore(
        session: URLSession? = nil,
        hostsFileURL: URL,
        isBenchmarkEnabled: @escaping () -> Bool = { false },
        isTestRun: @escaping () -> Bool = { false }
    ) -> GitHubAvatarStore {
        GitHubAvatarStore(
            session: session ?? stubSession(),
            hostsFileURL: hostsFileURL,
            environment: { [:] },
            home: { "/Users/nobody" },
            isBenchmarkEnabled: isBenchmarkEnabled,
            isTestRun: isTestRun
        )
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubAvatarURLProtocolStub.self]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private func writeHostsFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gh-hosts-\(UUID().uuidString).yml")
        let yaml = """
        github.com:
            user: octocat
            oauth_token: dummy-oauth-token-never-copy
        """
        try Data(yaml.utf8).write(to: url)
        return url
    }
}

private class GitHubAvatarURLProtocolStub: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var body: Data = .init()
        var contentType: String = "image/png"
        var error: Error?
    }

    static let lastRequest = LockedBox<URLRequest?>(nil)
    static let loadCount = LockedBox(0)
    static let response = LockedBox(Response())

    static func reset() {
        lastRequest.mutate { $0 = nil }
        loadCount.mutate { $0 = 0 }
        response.mutate { $0 = Response() }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.loadCount.mutate { $0 += 1 }
        Self.lastRequest.mutate { $0 = request }
        let response = Self.response.value
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let http = HTTPURLResponse(
                  url: url,
                  statusCode: response.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": response.contentType]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
