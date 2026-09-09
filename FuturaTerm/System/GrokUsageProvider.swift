import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "GrokUsageProvider")

enum GrokRFC3339 {
    static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

enum GrokAuthFile {
    struct Credentials: Equatable {
        var key: String
        var userId: String?
        var email: String?
        var expiresAt: Date?

        func isValid(at now: Date) -> Bool {
            guard !key.isEmpty else { return false }
            if let expiresAt {
                return expiresAt > now
            }
            return true
        }
    }

    /// `$GROK_HOME` when that env var is set and non-empty, else `~/.grok`
    /// via `$HOME`-first `ProjectPath.currentHome`.
    static func homeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = ProjectPath.currentHome
    ) -> URL {
        if let grokHome = environment["GROK_HOME"], !grokHome.isEmpty {
            return URL(fileURLWithPath: grokHome, isDirectory: true)
        }
        return URL(fileURLWithPath: home + "/.grok", isDirectory: true)
    }

    /// `$GROK_HOME/auth.json` when that env var is set and non-empty, else
    /// `~/.grok/auth.json` via `$HOME`-first `ProjectPath.currentHome`.
    static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = ProjectPath.currentHome
    ) -> URL {
        homeDirectory(environment: environment, home: home)
            .appendingPathComponent("auth.json")
    }

    static func load(from url: URL) -> Credentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// Top-level map of issuer → entry. Prefers a key starting with
    /// `https://auth.x.ai::`; otherwise the first (issuer-sorted) entry with a
    /// non-empty `key`.
    static func parse(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let preferred = root.keys.filter { $0.hasPrefix("https://auth.x.ai::") }.sorted()
        for issuer in preferred {
            if let credentials = credentials(from: root[issuer]) {
                return credentials
            }
        }
        for issuer in root.keys.sorted() {
            if let credentials = credentials(from: root[issuer]) {
                return credentials
            }
        }
        return nil
    }

    private static func credentials(from value: Any?) -> Credentials? {
        guard let map = value as? [String: Any] else { return nil }
        guard let key = map["key"] as? String, !key.isEmpty else { return nil }
        let userId = string(map["user_id"]) ?? string(map["userId"])
        let expiresRaw = string(map["expires_at"]) ?? string(map["expiresAt"])
        return Credentials(
            key: key,
            userId: userId,
            email: string(map["email"]),
            expiresAt: expiresRaw.flatMap(GrokRFC3339.parse)
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}

enum GrokBillingParser {
    static func parse(
        _ data: Data,
        fetchedAt: Date,
        kind: AgentUsageKind = .grok
    ) throws -> AgentUsageSnapshot {
        guard !data.isEmpty else { throw AgentUsageError.unavailable }
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentUsageError.decodeFailed
            }
            root = object
        } catch let error as AgentUsageError {
            throw error
        } catch {
            throw AgentUsageError.decodeFailed
        }

        if root["config"] is NSNull {
            throw AgentUsageError.decodeFailed
        }

        let config = root["config"] as? [String: Any]
        let endRaw = periodEnd(config: config, root: root)

        if let percent = creditUsagePercent(config: config) {
            let usedFraction = min(1, max(0, percent / 100))
            return AgentUsageSnapshot(
                kind: kind,
                usedFraction: usedFraction,
                periodEnd: endRaw.flatMap(GrokRFC3339.parse),
                fetchedAt: fetchedAt
            )
        }

        let used = jsonDouble(moneyVal(config?["used"]) ?? moneyVal(root["used"]))
        let limit = jsonDouble(moneyVal(config?["monthlyLimit"]) ?? moneyVal(root["monthlyLimit"]))
        if let used, let limit, limit > 0 {
            let usedFraction = min(1, max(0, used / limit))
            return AgentUsageSnapshot(
                kind: kind,
                usedFraction: usedFraction,
                periodEnd: endRaw.flatMap(GrokRFC3339.parse),
                fetchedAt: fetchedAt
            )
        }

        // Unified-billing accounts dropped `creditUsagePercent` and send
        // `monthlyLimit.val = 0`. That is still a valid logged-in quota
        // window — hiding the footer looked like a signed-out app.
        if isRecognizedUncappedConfig(config: config, used: used, limit: limit) {
            return AgentUsageSnapshot(
                kind: kind,
                usedFraction: 0,
                periodEnd: endRaw.flatMap(GrokRFC3339.parse),
                fetchedAt: fetchedAt
            )
        }

        throw AgentUsageError.decodeFailed
    }

    /// `format=credits` puts the quota on `creditUsagePercent`, and also on
    /// `productUsage[].usagePercent` for Grok Build. Prefer the top-level
    /// percent; fall back to the GrokBuild row, then any product row.
    private static func creditUsagePercent(config: [String: Any]?) -> Double? {
        guard let config else { return nil }
        if let percent = jsonDouble(config["creditUsagePercent"]) {
            return percent
        }
        guard let products = config["productUsage"] as? [[String: Any]] else { return nil }
        if let grokBuild = products.first(where: { ($0["product"] as? String) == "GrokBuild" }),
           let percent = jsonDouble(grokBuild["usagePercent"])
        {
            return percent
        }
        return products.lazy.compactMap { jsonDouble($0["usagePercent"]) }.first
    }

    private static func periodEnd(config: [String: Any]?, root: [String: Any]) -> String? {
        if let end = (config?["currentPeriod"] as? [String: Any])?["end"] as? String {
            return end
        }
        if let end = config?["billingPeriodEnd"] as? String {
            return end
        }
        return root["billingPeriodEnd"] as? String
    }

    private static func moneyVal(_ value: Any?) -> Any? {
        (value as? [String: Any])?["val"]
    }

    private static func isRecognizedUncappedConfig(
        config: [String: Any]?,
        used: Double?,
        limit: Double?
    ) -> Bool {
        if used != nil, limit == nil || limit == 0 { return true }
        guard let config else { return false }
        if config["isUnifiedBillingUser"] is NSNumber { return true }
        if config["prepaidBalance"] != nil { return true }
        if config["currentPeriod"] != nil { return true }
        if config["billingPeriodEnd"] is String { return true }
        return false
    }

    private static func jsonDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            // JSON booleans are NSNumber; reject them so `true` isn't 1%.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            return number.doubleValue
        case let value as Double: return value
        case let value as Int: return Double(value)
        default: return nil
        }
    }
}

/// Rejects HTTP redirects so a `Bearer` header cannot follow to another host.
private final class GrokBillingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct GrokUsageProvider: AgentUsageProvider {
    var kind: AgentUsageKind { .grok }

    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    let authFileURL: URL?
    let now: @Sendable () -> Date
    let session: URLSession

    init(
        authFileURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        session: URLSession = GrokUsageProvider.makeSession()
    ) {
        self.authFileURL = authFileURL
        self.now = now
        self.session = session
    }

    private static let redirectDelegate = GrokBillingRedirectDelegate()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    func isAuthenticated() -> Bool {
        guard let credentials = GrokAuthFile.load(from: resolvedAuthURL()) else { return false }
        return credentials.isValid(at: now())
    }

    func accountLabel() -> String? {
        guard let credentials = GrokAuthFile.load(from: resolvedAuthURL()),
              credentials.isValid(at: now())
        else {
            return nil
        }
        if let email = credentials.email {
            return email
        }
        return kind.displayName
    }

    func fetch() async throws -> AgentUsageSnapshot {
        guard let credentials = GrokAuthFile.load(from: resolvedAuthURL()),
              credentials.isValid(at: now())
        else {
            throw AgentUsageError.unauthenticated
        }

        var request = URLRequest(url: Self.billingURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credentials.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        if let userId = credentials.userId {
            request.setValue(userId, forHTTPHeaderField: "x-userid")
        }
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AgentUsageError.unavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw AgentUsageError.unavailable
        }
        logger.info("Grok billing HTTP \(http.statusCode, privacy: .public)")

        switch http.statusCode {
        case 200 ..< 300:
            guard !data.isEmpty else { throw AgentUsageError.unavailable }
            do {
                return try GrokBillingParser.parse(data, fetchedAt: now())
            } catch {
                logger.info("Grok billing decode failed")
                throw error
            }
        case 401:
            throw AgentUsageError.unauthenticated
        default:
            throw AgentUsageError.unavailable
        }
    }

    private func resolvedAuthURL() -> URL {
        authFileURL ?? GrokAuthFile.url()
    }
}
