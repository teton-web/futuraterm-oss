import AppKit
import IOSurface

/// Tracks a bounded set of follow-up samples for lifecycle and terminal events.
struct AdaptiveTerminalSamplingBurst {
    private(set) var retriesRemaining = 0

    mutating func request(retries: Int) {
        retriesRemaining = max(retriesRemaining, max(0, retries))
    }

    mutating func consumeRetry() -> Bool {
        guard retriesRemaining > 0 else { return false }
        retriesRemaining -= 1
        return true
    }

    mutating func cancel() {
        retriesRemaining = 0
    }
}

/// Samples every visible pane in the active terminal window and publishes its
/// temporary terminal-app background. A single pane may tint the whole window;
/// split panes are always isolated to their own bounds. Sampling is event-driven
/// by output, render, and focus changes, with bounded retries for frames that
/// arrive shortly after those events; there is no idle polling.
@MainActor
final class AdaptiveTerminalChrome {
    static let shared = AdaptiveTerminalChrome()

    private var stabilizers: [UUID: AdaptiveTerminalBackgroundStabilizer] = [:]
    private var sampleTimer: Timer?
    private var retryTimer: Timer?
    private var samplingBurst = AdaptiveTerminalSamplingBurst()

    private init() {}

    func preferenceDidEnable() {
        requestSamplingBurst(delay: 0, retries: 3)
    }

    /// Property observers do not run while `Preferences` initializes, so a
    /// persisted enabled value needs one explicit lifecycle handoff after the
    /// main window exists.
    func mainWindowDidAppear() {
        guard Preferences.shared.adaptiveTerminalChromeEnabled else { return }
        preferenceDidEnable()
    }

    func preferenceDidDisable() {
        cancelTimers()
        stabilizers.removeAll()
        for view in GhosttyTerminalNSView.allLiveViews() {
            clearPresentation(of: view)
        }
        GhosttyApp.shared.adoptAdaptiveBackgroundColor(nil)
    }

    /// Focus changes accompany tab switches, where the view may not be
    /// attached to its window yet mid-transition — so this cannot demand
    /// visibility the way render events do. `sampleVisiblePanes` re-derives
    /// the eligible set when the timer fires, one run-loop turn later.
    func focusDidChange(to _: GhosttyTerminalNSView) {
        guard Preferences.shared.adaptiveTerminalChromeEnabled else { return }
        requestSamplingBurst(delay: 0, retries: 2)
    }

    func terminalDidRender(_ view: GhosttyTerminalNSView) {
        guard shouldHandleEvent(from: view) else { return }
        requestSamplingBurst(delay: 0.12, retries: 2)
    }

    /// The renderer action is not emitted by every GhosttyKit build, but the
    /// PTY output heartbeat reliably covers TUI startup and redraws. A short
    /// burst lets Metal publish the finished frame before the final sample.
    func terminalDidOutput(_ view: GhosttyTerminalNSView) {
        guard shouldHandleEvent(from: view) else { return }
        requestSamplingBurst(delay: 0.12, retries: 2)
    }

    /// OSC 11 is explicit terminal-native evidence and takes effect
    /// immediately; inferred IOSurface colors retain two-observation
    /// stabilization.
    func terminalBackgroundDidChange(_ color: NSColor, in view: GhosttyTerminalNSView) {
        guard shouldHandleEvent(from: view) else { return }
        let candidate = effectiveCandidate(color)
        var stabilizer = stabilizers[view.paneID] ?? AdaptiveTerminalBackgroundStabilizer()
        stabilizer.reset(to: candidate)
        stabilizers[view.paneID] = stabilizer
        refreshPresentation(for: monitoredViews())
    }

    func terminalBackgroundDidReset(in view: GhosttyTerminalNSView) {
        guard shouldHandleEvent(from: view) else { return }
        stabilizers[view.paneID] = AdaptiveTerminalBackgroundStabilizer()
        view.sampledDominantBackgroundColor = nil
        scheduleSample(delay: 0)
    }

    private func scheduleSample(delay: TimeInterval) {
        if let sampleTimer {
            // A tab switch asking for an immediate sample must not wait out a
            // longer render-debounce timer that is already pending.
            guard sampleTimer.fireDate > Date().addingTimeInterval(delay) else { return }
            sampleTimer.invalidate()
            self.sampleTimer = nil
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleTimer = nil
                self?.sampleVisiblePanes()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    private func requestSamplingBurst(delay: TimeInterval, retries: Int) {
        samplingBurst.request(retries: retries)
        scheduleSample(delay: delay)
    }

    private func sampleVisiblePanes() {
        guard Preferences.shared.adaptiveTerminalChromeEnabled else { return }
        let views = monitoredViews()
        pruneState(keeping: views)
        let shouldContinueBurst = samplingBurst.consumeRetry()
        guard !views.isEmpty else {
            GhosttyApp.shared.adoptAdaptiveBackgroundColor(nil)
            updateRetryTimer(isNeeded: shouldContinueBurst)
            return
        }

        let needsVerification = views.map(sample).contains(true)
        refreshPresentation(for: views)
        updateRetryTimer(isNeeded: needsVerification || shouldContinueBurst)
    }

    /// Returns true when this pane has a first, unconfirmed inferred
    /// observation and needs the short verification sample.
    private func sample(_ view: GhosttyTerminalNSView) -> Bool {
        let id = view.paneID
        // A pane returning from an occluded tab keeps its remembered color, so
        // seed the fresh stabilizer with it: re-observing the same color is a
        // no-op instead of a pending change, while a TUI that exited off-screen
        // still clears through the normal two-observation path.
        var stabilizer = stabilizers[id]
            ?? AdaptiveTerminalBackgroundStabilizer(seededWith: view.sampledDominantBackgroundColor)

        if let reported = effectiveCandidate(view.reportedBackgroundColor) {
            stabilizer.reset(to: reported)
            stabilizers[id] = stabilizer
            return false
        }

        let candidate: NSColor? = if let surface = view.layer?.contents as? IOSurface {
            effectiveCandidate(AdaptiveTerminalBackgroundDetector.dominantColor(in: surface)?.color)
        } else {
            nil
        }

        let change = stabilizer.observe(candidate)
        stabilizers[id] = stabilizer
        switch change {
        case .applyColor:
            view.sampledDominantBackgroundColor = candidate
        case .clear:
            view.sampledDominantBackgroundColor = nil
        case nil:
            break
        }
        return stabilizer.hasPendingObservation
    }

    private func refreshPresentation(for views: [GhosttyTerminalNSView]) {
        let candidates = views.map(currentCandidate)
        // Every detected color fills its pane opaquely, including a lone pane.
        // The window-wide tint follows window opacity, so without this fill a
        // translucent seam would remain around the TUI's opaque pixels.
        for (view, color) in zip(views, candidates) {
            view.presentAdaptivePaneBackground(color)
        }
        // A lone pane can lend its color to the whole window. In a split, each
        // color stays pane-local and the configured background owns the chrome.
        GhosttyApp.shared.adoptAdaptiveBackgroundColor(candidates.count == 1 ? candidates[0] : nil)
    }

    private func currentCandidate(for view: GhosttyTerminalNSView) -> NSColor? {
        effectiveCandidate(view.reportedBackgroundColor)
            ?? effectiveCandidate(view.sampledDominantBackgroundColor)
    }

    private func updateRetryTimer(isNeeded: Bool) {
        guard isNeeded else {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryTimer = nil
                self?.sampleVisiblePanes()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func monitoredViews() -> [GhosttyTerminalNSView] {
        let eligible = GhosttyTerminalNSView.allLiveViews().filter(isVisible)
        guard let window = preferredWindow(from: eligible) else { return [] }
        return eligible.filter { $0.window === window }
    }

    private func preferredWindow(from views: [GhosttyTerminalNSView]) -> NSWindow? {
        if let key = NSApp.keyWindow, views.contains(where: { $0.window === key }) {
            return key
        }
        if let main = NSApp.mainWindow, views.contains(where: { $0.window === main }) {
            return main
        }
        return views.first(where: { !($0.window is NSPanel) })?.window ?? views.first?.window
    }

    private func shouldHandleEvent(from view: GhosttyTerminalNSView) -> Bool {
        guard Preferences.shared.adaptiveTerminalChromeEnabled, isVisible(view) else { return false }
        return monitoredViews().contains { $0 === view }
    }

    private func isVisible(_ view: GhosttyTerminalNSView) -> Bool {
        guard let window = view.window,
              window.occlusionState.contains(.visible),
              !view.isHiddenOrHasHiddenAncestor,
              view.bounds.width > 0,
              view.bounds.height > 0
        else { return false }
        return true
    }

    private func effectiveCandidate(_ color: NSColor?) -> NSColor? {
        Self.effectiveCandidate(color, configuredBackground: GhosttyApp.shared.backgroundColor)
    }

    static func effectiveCandidate(
        _ color: NSColor?,
        configuredBackground: NSColor,
        minimumDistance: CGFloat = 0.04
    ) -> NSColor? {
        guard let color else { return nil }
        return color.distance(to: configuredBackground) >= minimumDistance ? color : nil
    }

    /// Drops only the stabilizers of panes that left the monitored set. Their
    /// remembered colors and pane fills survive occlusion on purpose: a
    /// revisited tab presents its TUI background immediately instead of
    /// flashing the configured theme while detection restarts from zero.
    private func pruneState(keeping views: [GhosttyTerminalNSView]) {
        let active = Set(views.map(\.paneID))
        stabilizers = stabilizers.filter { active.contains($0.key) }
    }

    private func clearPresentation(of view: GhosttyTerminalNSView) {
        view.sampledDominantBackgroundColor = nil
        view.presentAdaptivePaneBackground(nil)
    }

    private func cancelTimers() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        samplingBurst.cancel()
    }
}
