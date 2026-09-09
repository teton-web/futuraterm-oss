import Foundation
import Observation
import os

private let logger = Logger(subsystem: appBundleID, category: "GrokSessionStore")

/// Per-pane Grok session chrome (start date), resolved from `~/.grok/sessions`.
/// Cached against the zmx session name + grok pid so the 250ms poll never
/// re-lists file descriptors.
@MainActor
@Observable
final class GrokSessionStore {
    private(set) var chromeBySessionName: [String: GrokSessionChrome] = [:]

    @ObservationIgnored
    private let lookup: @Sendable (pid_t, String?, String) -> GrokSessionChrome?
    @ObservationIgnored
    private let grokHome: () -> String
    @ObservationIgnored
    private let isBenchmarkEnabled: () -> Bool
    @ObservationIgnored
    private let isTestRun: () -> Bool
    @ObservationIgnored
    private var pidBySession: [String: pid_t] = [:]
    @ObservationIgnored
    private var inFlight: Set<String> = []

    init(
        lookup: @escaping @Sendable (pid_t, String?, String) -> GrokSessionChrome?
            = GrokSessionLookup.resolve,
        grokHome: @escaping () -> String = { GrokAuthFile.homeDirectory().path },
        isBenchmarkEnabled: @escaping () -> Bool = { BenchmarkControl.isEnabled },
        isTestRun: @escaping () -> Bool = { Preferences.isTestRun }
    ) {
        self.lookup = lookup
        self.grokHome = grokHome
        self.isBenchmarkEnabled = isBenchmarkEnabled
        self.isTestRun = isTestRun
    }

    private var skipsIO: Bool {
        isBenchmarkEnabled() || isTestRun()
    }

    func glanceLabel(for sessionName: String, now: Date = Date()) -> String? {
        guard let chrome = chromeBySessionName[sessionName] else { return nil }
        return GrokSessionAge.promptGlance(created: chrome.createdAt, now: now)
    }

    func detailLine(for sessionName: String, now: Date = Date()) -> String? {
        guard let chrome = chromeBySessionName[sessionName] else { return nil }
        return GrokSessionAge.detailLine(
            created: chrome.createdAt,
            updated: chrome.updatedAt,
            now: now
        )
    }

    /// Test/preview seam: publish chrome without touching the filesystem.
    func cache(_ chrome: GrokSessionChrome, for sessionName: String) {
        chromeBySessionName[sessionName] = chrome
    }

    /// Resolve once per (session name, grok pid). Cheap no-op when already
    /// cached for that pid.
    func resolve(sessionName: String, pid: pid_t?, cwd: String?) {
        guard !skipsIO else { return }
        guard let pid, pid > 0 else { return }
        if pidBySession[sessionName] == pid, chromeBySessionName[sessionName] != nil {
            return
        }
        guard !inFlight.contains(sessionName) else { return }
        inFlight.insert(sessionName)
        let home = grokHome()
        let lookup = lookup
        Task { [weak self] in
            let chrome = await Task.detached {
                lookup(pid, cwd, home)
            }.value
            await MainActor.run {
                guard let self else { return }
                self.inFlight.remove(sessionName)
                self.pidBySession[sessionName] = pid
                if let chrome {
                    self.chromeBySessionName[sessionName] = chrome
                    logger.info(
                        "grok session \(sessionName, privacy: .public) id \(chrome.sessionID, privacy: .public)"
                    )
                }
            }
        }
    }
}
