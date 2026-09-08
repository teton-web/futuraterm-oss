import AppKit
import Foundation
import Observation
import os

private let logger = Logger(subsystem: appBundleID, category: "AgentUsageStore")

/// Account-level coding-agent quota, refreshed on its own 5-minute timer —
/// not via `AppState.pollNow` (that path is 250ms and must stay cheap).
@MainActor
@Observable
final class AgentUsageStore {
    static let refreshInterval: TimeInterval = 5 * 60
    private(set) var snapshots: [AgentUsageSnapshot] = []
    /// Signed-in accounts for the footer chip. Updated from the filesystem
    /// even when `showAgentUsage` is off (no billing HTTP in that case).
    private(set) var accounts: [AgentAccount] = []

    @ObservationIgnored
    private let providers: [any AgentUsageProvider]
    @ObservationIgnored
    private let isBenchmarkEnabled: () -> Bool
    @ObservationIgnored
    private let isTestRun: () -> Bool
    @ObservationIgnored
    private let isUsageEnabled: () -> Bool
    @ObservationIgnored
    private let isAppActive: () -> Bool
    @ObservationIgnored
    private let isAnyWindowVisible: () -> Bool

    @ObservationIgnored
    private var started = false
    @ObservationIgnored
    nonisolated(unsafe) private var timer: Timer?
    @ObservationIgnored
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored
    private var inFlight: Task<Void, Never>?

    init(
        providers: [any AgentUsageProvider] = [GrokUsageProvider()],
        isBenchmarkEnabled: @escaping () -> Bool = { BenchmarkControl.isEnabled },
        isTestRun: @escaping () -> Bool = { Preferences.isTestRun },
        isUsageEnabled: @escaping () -> Bool = { Preferences.shared.showAgentUsage },
        isAppActive: @escaping () -> Bool = { NSApp?.isActive ?? false },
        isAnyWindowVisible: @escaping () -> Bool = {
            (NSApp?.windows ?? []).contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        }
    ) {
        self.providers = providers
        self.isBenchmarkEnabled = isBenchmarkEnabled
        self.isTestRun = isTestRun
        self.isUsageEnabled = isUsageEnabled
        self.isAppActive = isAppActive
        self.isAnyWindowVisible = isAnyWindowVisible
    }

    deinit {
        let timer = timer
        let tokens = observerTokens
        // Timer was scheduled on the main run loop; deinit is nonisolated.
        DispatchQueue.main.async {
            timer?.invalidate()
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        guard !skipsNetwork else { return }
        installObservers()
        syncTimer(refreshIfStarting: true)
        // Timer (and its first fetch) only runs while usage is on. Account
        // labels are filesystem-only and must still publish when it's off.
        if !isUsageEnabled() {
            refreshAccounts()
        }
    }

    /// Settings / sidebar toggle: start the timer and fetch on enable, stop
    /// the timer on disable. Always re-reads account labels so the chip
    /// still appears when usage is off. Does not require an activation event.
    func noteUsagePreferenceChanged() async {
        guard started, !skipsNetwork else { return }
        syncTimer(refreshIfStarting: true)
        await refresh()
    }

    func refresh() async {
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

    private func performRefresh() async {
        guard !skipsNetwork else { return }
        refreshAccounts()
        guard isUsageEnabled() else { return }

        for provider in providers {
            let kind = provider.kind
            guard provider.isAuthenticated() else { continue }
            let outcome = await Task.detached {
                try await provider.fetch()
            }.result
            switch outcome {
            case let .success(snapshot):
                upsert(snapshot)
                logger.info(
                    "\(kind.rawValue, privacy: .public) remaining \(snapshot.remainingPercent, privacy: .public) percent"
                )
            case let .failure(error) where (error as? AgentUsageError) == .unauthenticated:
                removeSnapshot(kind: kind)
            case .failure:
                markStale(kind: kind)
            }
        }
    }

    /// Filesystem only — never hits the billing API.
    private func refreshAccounts() {
        for provider in providers {
            let kind = provider.kind
            if provider.isAuthenticated(), let label = provider.accountLabel() {
                upsert(AgentAccount(kind: kind, label: label))
            } else {
                removeSnapshot(kind: kind)
                removeAccount(kind: kind)
            }
        }
    }

    private func upsert(_ snapshot: AgentUsageSnapshot) {
        if let index = snapshots.firstIndex(where: { $0.kind == snapshot.kind }) {
            snapshots[index] = snapshot
        } else {
            snapshots.append(snapshot)
        }
    }

    private func upsert(_ account: AgentAccount) {
        if let index = accounts.firstIndex(where: { $0.kind == account.kind }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    private func removeSnapshot(kind: AgentUsageKind) {
        snapshots.removeAll { $0.kind == kind }
    }

    private func removeAccount(kind: AgentUsageKind) {
        accounts.removeAll { $0.kind == kind }
    }

    private func markStale(kind: AgentUsageKind) {
        guard let index = snapshots.firstIndex(where: { $0.kind == kind }) else { return }
        snapshots[index].isStale = true
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let onActivate: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncTimer(refreshIfStarting: false)
                Task { await self?.refresh() }
            }
        }
        let onVisibility: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncTimer(refreshIfStarting: true)
            }
        }
        observerTokens = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main,
                using: onActivate
            ),
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main,
                using: onVisibility
            ),
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: nil,
                queue: .main,
                using: onVisibility
            ),
        ]
    }

    private func syncTimer(refreshIfStarting: Bool) {
        guard !skipsNetwork else { return }
        let shouldRun = isUsageEnabled() && (isAppActive() || isAnyWindowVisible())
        if shouldRun {
            let starting = timer == nil
            if starting {
                let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        await self?.refresh()
                    }
                }
                timer.tolerance = Self.refreshInterval / 10
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
            if starting, refreshIfStarting {
                Task { await refresh() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}
