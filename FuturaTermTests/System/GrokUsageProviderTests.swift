import Foundation
@testable import FuturaTerm
import Testing

struct GrokUsageProviderTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func prefers_auth_x_ai_issuer_over_legacy() throws {
        let json = """
        {
          "https://accounts.x.ai/sign-in": { "key": "legacy-dummy-key" },
          "https://auth.x.ai::client": {
            "key": "xai-dummy-preferred",
            "user_id": "user-1"
          }
        }
        """
        let credentials = try #require(GrokAuthFile.parse(Data(json.utf8)))
        #expect(credentials.key == "xai-dummy-preferred")
        #expect(credentials.userId == "user-1")
    }

    @Test
    func preferred_issuer_parses_email() throws {
        let json = """
        {
          "https://accounts.x.ai/sign-in": { "key": "legacy-dummy-key" },
          "https://auth.x.ai::client": {
            "key": "xai-dummy-preferred",
            "user_id": "123e4567-e89b-12d3-a456-426614174000",
            "email": "user@example.com"
          }
        }
        """
        let credentials = try #require(GrokAuthFile.parse(Data(json.utf8)))
        #expect(credentials.key == "xai-dummy-preferred")
        #expect(credentials.email == "user@example.com")
    }

    @Test
    func missing_email_is_nil() throws {
        let json = """
        {
          "https://auth.x.ai::client": {
            "key": "xai-dummy-preferred",
            "user_id": "123e4567-e89b-12d3-a456-426614174000"
          }
        }
        """
        let credentials = try #require(GrokAuthFile.parse(Data(json.utf8)))
        #expect(credentials.email == nil)
        #expect(credentials.userId == "123e4567-e89b-12d3-a456-426614174000")
    }

    @Test
    func account_label_uses_email() throws {
        let url = try writeAuthFile("""
        {
          "https://auth.x.ai::client": {
            "key": "dummy-no-expiry-key",
            "email": "user@example.com"
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = GrokUsageProvider(authFileURL: url, now: { Date() })
        #expect(provider.accountLabel() == "user@example.com")
    }

    @Test
    func account_label_falls_back_to_grok_without_email() throws {
        let url = try writeAuthFile("""
        {
          "https://auth.x.ai::client": {
            "key": "dummy-no-expiry-key",
            "user_id": "123e4567-e89b-12d3-a456-426614174000"
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = GrokUsageProvider(authFileURL: url, now: { Date() })
        #expect(provider.isAuthenticated())
        #expect(provider.accountLabel() == "Grok")
    }

    @Test
    func expired_token_has_no_account_label() throws {
        let url = try writeAuthFile("""
        {
          "https://auth.x.ai::client": {
            "key": "dummy-expired-key",
            "email": "user@example.com",
            "expires_at": "2020-01-01T00:00:00Z"
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = GrokUsageProvider(authFileURL: url, now: { Date() })
        #expect(provider.accountLabel() == nil)
    }

    @Test
    func falls_back_to_first_issuer_sorted_non_empty_key() throws {
        let json = """
        {
          "https://zzz.example/b": { "key": "zzz-dummy-key" },
          "https://aaa.example/a": { "key": "aaa-dummy-key" }
        }
        """
        let credentials = try #require(GrokAuthFile.parse(Data(json.utf8)))
        #expect(credentials.key == "aaa-dummy-key")
    }

    @Test
    func empty_preferred_key_falls_through_to_legacy() throws {
        let json = """
        {
          "https://auth.x.ai::client": { "key": "" },
          "https://accounts.x.ai/sign-in": { "key": "legacy-dummy-key" }
        }
        """
        let credentials = try #require(GrokAuthFile.parse(Data(json.utf8)))
        #expect(credentials.key == "legacy-dummy-key")
    }

    @Test
    func missing_auth_file_is_not_authenticated() {
        let url = URL(fileURLWithPath: "/tmp/futuraterm-missing-grok-auth-\(UUID().uuidString).json")
        let provider = GrokUsageProvider(authFileURL: url, now: { Date() })
        #expect(!provider.isAuthenticated())
    }

    @Test
    func expired_token_is_not_authenticated() throws {
        let url = try writeAuthFile("""
        {
          "https://auth.x.ai::client": {
            "key": "dummy-expired-key",
            "expires_at": "2020-01-01T00:00:00Z"
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let provider = GrokUsageProvider(authFileURL: url, now: { Date() })
        #expect(!provider.isAuthenticated())
    }

    @Test
    func missing_expiry_is_authenticated() throws {
        let url = try writeAuthFile("""
        { "https://auth.x.ai::client": { "key": "dummy-no-expiry-key" } }
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = GrokUsageProvider(authFileURL: url, now: { Date() })
        #expect(provider.isAuthenticated())
    }

    @Test
    func future_expiry_is_authenticated() throws {
        let url = try writeAuthFile("""
        {
          "https://auth.x.ai::client": {
            "key": "dummy-future-key",
            "expires_at": "2099-01-01T00:00:00Z"
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let now = try #require(GrokRFC3339.parse("2026-01-01T00:00:00Z"))
        let provider = GrokUsageProvider(authFileURL: url, now: { now })
        #expect(provider.isAuthenticated())
    }

    @Test
    func grok_home_overrides_default_auth_path() {
        let url = GrokAuthFile.url(environment: ["GROK_HOME": "/tmp/dummy-grok-home"], home: "/Users/nobody")
        #expect(url.path == "/tmp/dummy-grok-home/auth.json")
    }

    @Test
    func empty_grok_home_uses_home_dot_grok() {
        let url = GrokAuthFile.url(environment: ["GROK_HOME": ""], home: "/Users/nobody")
        #expect(url.path == "/Users/nobody/.grok/auth.json")
    }

    @Test
    func credits_json_uses_percent_and_period_end() throws {
        let json = """
        {
          "config": {
            "creditUsagePercent": 42.5,
            "currentPeriod": { "end": "2026-12-31T00:00:00Z" },
            "prepaidBalance": { "val": 999 }
          },
          "productUsage": { "ignored": true },
          "history": []
        }
        """
        let snapshot = try GrokBillingParser.parse(Data(json.utf8), fetchedAt: fetchedAt)
        #expect(snapshot.kind == .grok)
        #expect(snapshot.usedFraction == 0.425)
        #expect(snapshot.remainingPercent == 58)
        #expect(snapshot.periodEnd == GrokRFC3339.parse("2026-12-31T00:00:00Z"))
        #expect(!snapshot.isStale)
    }

    @Test
    func extra_keys_are_ignored() throws {
        let json = """
        {
          "config": { "creditUsagePercent": 10 },
          "productUsage": { "foo": 1 },
          "history": [1, 2, 3]
        }
        """
        let snapshot = try GrokBillingParser.parse(Data(json.utf8), fetchedAt: fetchedAt)
        #expect(snapshot.usedFraction == 0.10)
        #expect(snapshot.remainingPercent == 90)
    }

    @Test
    func zero_credit_usage_percent_is_fully_remaining() throws {
        let json = Data(#"{ "config": { "creditUsagePercent": 0 } }"#.utf8)
        let snapshot = try GrokBillingParser.parse(json, fetchedAt: fetchedAt)
        #expect(snapshot.usedFraction == 0)
        #expect(snapshot.remainingPercent == 100)
    }

    @Test
    func boolean_credit_usage_percent_is_decode_failed() {
        let json = Data(#"{ "config": { "creditUsagePercent": true } }"#.utf8)
        #expect(throws: AgentUsageError.decodeFailed) {
            try GrokBillingParser.parse(json, fetchedAt: fetchedAt)
        }
    }

    @Test
    func zero_monthly_limit_is_uncapped_full_remaining() throws {
        let json = Data(#"{ "used": { "val": 0 }, "monthlyLimit": { "val": 0 } }"#.utf8)
        let snapshot = try GrokBillingParser.parse(json, fetchedAt: fetchedAt)
        #expect(snapshot.usedFraction == 0)
        #expect(snapshot.remainingPercent == 100)
    }

    @Test
    func config_nested_used_and_limit() throws {
        let json = """
        {
          "config": {
            "used": { "val": 250 },
            "monthlyLimit": { "val": 1000 },
            "billingPeriodEnd": "2026-09-01T00:00:00+00:00"
          }
        }
        """
        let snapshot = try GrokBillingParser.parse(Data(json.utf8), fetchedAt: fetchedAt)
        #expect(snapshot.usedFraction == 0.25)
        #expect(snapshot.remainingPercent == 75)
        #expect(snapshot.periodEnd == GrokRFC3339.parse("2026-09-01T00:00:00+00:00"))
    }

    @Test
    func credits_format_percent_and_grokbuild_product_usage() throws {
        let json = """
        {
          "config": {
            "creditUsagePercent": 25,
            "productUsage": [{ "product": "GrokBuild", "usagePercent": 25 }],
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "end": "2026-09-04T16:24:11.346320+00:00"
            },
            "isUnifiedBillingUser": true,
            "prepaidBalance": { "val": 0 }
          }
        }
        """
        let snapshot = try GrokBillingParser.parse(Data(json.utf8), fetchedAt: fetchedAt)
        #expect(snapshot.usedFraction == 0.25)
        #expect(snapshot.remainingPercent == 75)
        #expect(snapshot.periodEnd == GrokRFC3339.parse("2026-09-04T16:24:11.346320+00:00"))
    }

    @Test
    func grokbuild_product_usage_percent_when_top_level_percent_missing() throws {
        let json = """
        {
          "config": {
            "productUsage": [{ "product": "GrokBuild", "usagePercent": 40 }],
            "billingPeriodEnd": "2026-09-04T16:24:11.346320+00:00"
          }
        }
        """
        let snapshot = try GrokBillingParser.parse(Data(json.utf8), fetchedAt: fetchedAt)
        #expect(snapshot.usedFraction == 0.40)
        #expect(snapshot.remainingPercent == 60)
    }

    @Test
    func unified_billing_credits_payload_is_uncapped_full_remaining() throws {
        let json = """
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-08-28T16:24:11.346320+00:00",
              "end": "2026-09-04T16:24:11.346320+00:00"
            },
            "onDemandCap": { "val": 0 },
            "onDemandUsed": { "val": 0 },
            "isUnifiedBillingUser": true,
            "prepaidBalance": { "val": 0 },
            "billingPeriodEnd": "2026-09-04T16:24:11.346320+00:00"
          }
        }
        """
        let snapshot = try GrokBillingParser.parse(Data(json.utf8), fetchedAt: fetchedAt)
        #expect(snapshot.usedFraction == 0)
        #expect(snapshot.remainingPercent == 100)
        #expect(snapshot.periodEnd == GrokRFC3339.parse("2026-09-04T16:24:11.346320+00:00"))
    }

    @Test
    func rfc3339_parses_offset_and_fractional_offset() {
        #expect(GrokRFC3339.parse("2026-09-01T00:00:00+00:00") != nil)
        #expect(GrokRFC3339.parse("2026-09-04T16:24:11.346320+00:00") != nil)
        #expect(GrokRFC3339.parse("2026-08-28T22:24:33.399017Z") != nil)
    }

    @Test
    func empty_body_is_unavailable() {
        #expect(throws: AgentUsageError.unavailable) {
            try GrokBillingParser.parse(Data(), fetchedAt: fetchedAt)
        }
    }

    @Test
    func legacy_used_over_monthly_limit() throws {
        let json = """
        {
          "used": { "val": 1234 },
          "monthlyLimit": { "val": 2000 },
          "billingPeriodEnd": "2026-06-30T00:00:00Z"
        }
        """
        let snapshot = try GrokBillingParser.parse(Data(json.utf8), fetchedAt: fetchedAt)
        #expect(snapshot.usedFraction == 1234.0 / 2000.0)
        #expect(abs(snapshot.usedFraction - 0.617) < 0.0005)
        #expect(snapshot.periodEnd == GrokRFC3339.parse("2026-06-30T00:00:00Z"))
    }

    @Test
    func null_config_is_decode_failed() {
        let json = Data(#"{ "config": null }"#.utf8)
        #expect(throws: AgentUsageError.decodeFailed) {
            try GrokBillingParser.parse(json, fetchedAt: fetchedAt)
        }
    }

    @Test
    func missing_percent_and_limit_is_decode_failed() {
        let json = Data(#"{ "config": {} }"#.utf8)
        #expect(throws: AgentUsageError.decodeFailed) {
            try GrokBillingParser.parse(json, fetchedAt: fetchedAt)
        }
    }

    private func writeAuthFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }
}

@Suite(.serialized)
struct GrokUsageProviderHTTPTests {
    @Test
    func fetch_200_credits_json_and_headers() async throws {
        let auth = try writeAuthFile("""
        {
          "https://auth.x.ai::client": {
            "key": "dummy-http-key",
            "user_id": "user-http-1"
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: auth) }

        BillingURLProtocolStub.reset()
        BillingURLProtocolStub.response.mutate {
            $0 = .init(
                status: 200,
                body: Data(#"{ "config": { "creditUsagePercent": 25 } }"#.utf8)
            )
        }

        let provider = GrokUsageProvider(
            authFileURL: auth,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            session: stubSession()
        )
        let snapshot = try await provider.fetch()
        #expect(snapshot.usedFraction == 0.25)
        #expect(snapshot.remainingPercent == 75)

        let request = try #require(BillingURLProtocolStub.lastRequest.value)
        #expect(request.url == GrokUsageProvider.billingURL)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-http-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-XAI-Token-Auth") == "xai-grok-cli")
        #expect(request.value(forHTTPHeaderField: "x-userid") == "user-http-1")
        #expect(request.value(forHTTPHeaderField: "x-grok-client-version") == nil)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test
    func fetch_401_is_unauthenticated() async throws {
        let auth = try writeAuthFile(
            #"{ "https://auth.x.ai::client": { "key": "dummy-http-key" } }"#
        )
        defer { try? FileManager.default.removeItem(at: auth) }
        BillingURLProtocolStub.reset()
        BillingURLProtocolStub.response.mutate { $0 = .init(status: 401, body: Data()) }

        let provider = GrokUsageProvider(authFileURL: auth, session: stubSession())
        await #expect(throws: AgentUsageError.unauthenticated) {
            try await provider.fetch()
        }
    }

    @Test
    func fetch_302_is_unavailable() async throws {
        let auth = try writeAuthFile(
            #"{ "https://auth.x.ai::client": { "key": "dummy-http-key" } }"#
        )
        defer { try? FileManager.default.removeItem(at: auth) }
        BillingURLProtocolStub.reset()
        BillingURLProtocolStub.response.mutate { $0 = .init(status: 302, body: Data()) }

        let provider = GrokUsageProvider(authFileURL: auth, session: stubSession())
        await #expect(throws: AgentUsageError.unavailable) {
            try await provider.fetch()
        }
        let request = try #require(BillingURLProtocolStub.lastRequest.value)
        #expect(request.url == GrokUsageProvider.billingURL)
        #expect(request.httpMethod == "GET")
    }

    @Test
    func fetch_404_is_unavailable() async throws {
        let auth = try writeAuthFile(
            #"{ "https://auth.x.ai::client": { "key": "dummy-http-key" } }"#
        )
        defer { try? FileManager.default.removeItem(at: auth) }
        BillingURLProtocolStub.reset()
        BillingURLProtocolStub.response.mutate { $0 = .init(status: 404, body: Data()) }

        let provider = GrokUsageProvider(authFileURL: auth, session: stubSession())
        await #expect(throws: AgentUsageError.unavailable) {
            try await provider.fetch()
        }
    }

    @Test
    func fetch_empty_200_body_is_unavailable() async throws {
        let auth = try writeAuthFile(
            #"{ "https://auth.x.ai::client": { "key": "dummy-http-key" } }"#
        )
        defer { try? FileManager.default.removeItem(at: auth) }
        BillingURLProtocolStub.reset()
        BillingURLProtocolStub.response.mutate { $0 = .init(status: 200, body: Data()) }

        let provider = GrokUsageProvider(authFileURL: auth, session: stubSession())
        await #expect(throws: AgentUsageError.unavailable) {
            try await provider.fetch()
        }
    }

    @Test
    func fetch_transport_error_is_unavailable() async throws {
        let auth = try writeAuthFile(
            #"{ "https://auth.x.ai::client": { "key": "dummy-http-key" } }"#
        )
        defer { try? FileManager.default.removeItem(at: auth) }
        BillingURLProtocolStub.reset()
        BillingURLProtocolStub.response.mutate {
            $0 = .init(status: 200, body: Data(), error: URLError(.notConnectedToInternet))
        }

        let provider = GrokUsageProvider(authFileURL: auth, session: stubSession())
        await #expect(throws: AgentUsageError.unavailable) {
            try await provider.fetch()
        }
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingURLProtocolStub.self]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private func writeAuthFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-http-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }
}

private class BillingURLProtocolStub: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var body: Data = .init()
        var error: Error?
    }

    static let lastRequest = LockedBox<URLRequest?>(nil)
    static let response = LockedBox(Response())

    static func reset() {
        lastRequest.mutate { $0 = nil }
        response.mutate { $0 = Response() }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest.mutate { $0 = request }
        let response = Self.response.value
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(
            url: request.url ?? GrokUsageProvider.billingURL,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
