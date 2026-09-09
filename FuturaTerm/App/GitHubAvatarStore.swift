import AppKit
import Foundation
import Observation
import os

private let logger = Logger(subsystem: appBundleID, category: "GitHubAvatarStore")

/// Public GitHub avatar for the sidebar footer chip. Identity comes from the
/// gh CLI `hosts.yml`; the image is fetched without credentials.
@MainActor
@Observable
final class GitHubAvatarStore {
    private(set) var image: NSImage?

    @ObservationIgnored
    private let session: URLSession
    @ObservationIgnored
    private let hostsFileURL: URL?
    @ObservationIgnored
    private let environment: () -> [String: String]
    @ObservationIgnored
    private let home: () -> String
    @ObservationIgnored
    private let isBenchmarkEnabled: () -> Bool
    @ObservationIgnored
    private let isTestRun: () -> Bool

    @ObservationIgnored
    private var started = false
    @ObservationIgnored
    private var cachedIdentity: GitHubHostsFile.Identity?
    @ObservationIgnored
    private var inFlight: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []

    init(
        session: URLSession = GitHubAvatarStore.makeSession(),
        hostsFileURL: URL? = nil,
        environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        home: @escaping () -> String = { ProjectPath.currentHome },
        isBenchmarkEnabled: @escaping () -> Bool = { BenchmarkControl.isEnabled },
        isTestRun: @escaping () -> Bool = { Preferences.isTestRun }
    ) {
        self.session = session
        self.hostsFileURL = hostsFileURL
        self.environment = environment
        self.home = home
        self.isBenchmarkEnabled = isBenchmarkEnabled
        self.isTestRun = isTestRun
    }

    deinit {
        let tokens = observerTokens
        DispatchQueue.main.async {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    /// Ephemeral session that **allows** redirects (github.com png URLs 302
    /// to the avatar CDN). Do not reuse `GrokBillingRedirectDelegate`.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }

    func start() {
        guard !started else { return }
        started = true
        guard !skipsNetwork else { return }
        installObservers()
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        Task { await refresh() }
    }

    func refresh() async {
        guard !skipsNetwork else { return }
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private var skipsNetwork: Bool {
        isBenchmarkEnabled() || isTestRun()
    }

    private func resolvedHostsFileURL() -> URL {
        hostsFileURL ?? GitHubHostsFile.url(environment: environment(), home: home())
    }

    private func performRefresh() async {
        guard !skipsNetwork else { return }
        let identity = GitHubHostsFile.load(
            from: resolvedHostsFileURL(),
            environment: environment()
        )
        guard let identity, let avatarURL = GitHubHostsFile.avatarURL(for: identity) else {
            cachedIdentity = nil
            image = nil
            return
        }
        if identity == cachedIdentity, image != nil {
            return
        }
        if identity != cachedIdentity {
            image = nil
        }

        var request = URLRequest(url: avatarURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        // Public avatar URL only — never Authorization, never a token.

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let loaded = NSImage(data: data), loaded.isValid
            else {
                image = nil
                return
            }
            cachedIdentity = identity
            image = loaded
        } catch {
            image = nil
            logger.debug("github avatar fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func installObservers() {
        let onActivate: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRefresh()
            }
        }
        observerTokens = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main,
                using: onActivate
            ),
        ]
    }
}
