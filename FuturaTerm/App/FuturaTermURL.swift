import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "URLHandler")

/// `futuraterm://` LaunchServices grammar (v1).
///
/// Accepted forms:
/// - `futuraterm://open?path=<percent-encoded absolute-or-tilde path>`
/// - `futuraterm:///open?path=<…>` (Foundation's empty-host parse)
///
/// `run=` is ignored, and remote SSH specs (`host:dir`) are rejected, on
/// purpose: custom schemes can be invoked from a browser, so a `run` query
/// would be command injection into a terminal and a remote `path` would
/// spawn interactive ssh. Relative and unparseable paths are also nil.
enum FuturaTermURL {
    static let scheme = "futuraterm"

    enum Action: Equatable {
        /// Open or select the local project at `path` (absolute or `~`).
        /// The parser owns local-only validation (remotes, relatives, and
        /// unparseable specs are nil); directory existence stays
        /// `project.open`'s job.
        case open(path: String)
    }

    static func parse(_ url: URL) -> Action? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard command(from: url) == "open" else { return nil }
        guard let raw = queryValue("path", in: url) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        // Browser-invocable: only local abs/`~` paths become `.open`.
        guard case .local = ProjectPath.parse(path) else { return nil }
        return .open(path: path)
    }

    /// Host when present (`futuraterm://open?…`); otherwise the first path
    /// component (`futuraterm:///open?…`).
    private static func command(from url: URL) -> String? {
        if let host = url.host, !host.isEmpty {
            return host.lowercased()
        }
        let trimmed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let first = trimmed.split(separator: "/").first else { return nil }
        return String(first).lowercased()
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        return items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Queues LaunchServices URLs until a `ControlHandler` is attached, then
/// dispatches `project.open` with **only** the parsed path — never `run`.
@MainActor
final class FuturaTermURLRouter {
    private var pending: [URL] = []
    private var inFlight: Set<String> = []
    private var isFlushing = false
    private var handler: ControlHandler?

    /// Fire-and-forget attach for `installResponders`.
    func attach(_ handler: ControlHandler) {
        self.handler = handler
        Task { await flush() }
    }

    /// Fire-and-forget enqueue for `application(_:open:)` / `.onOpenURL`.
    func open(_ urls: [URL]) {
        enqueue(urls)
        Task { await flush() }
    }

    /// Test seam: attach and drain the queue before returning.
    func attachAndWait(_ handler: ControlHandler) async {
        self.handler = handler
        await flush()
    }

    /// Test seam: enqueue and drain before returning.
    func openAndWait(_ urls: [URL]) async {
        enqueue(urls)
        await flush()
    }

    private func enqueue(_ urls: [URL]) {
        for url in urls {
            let key = url.absoluteString
            if inFlight.contains(key) { continue }
            if pending.contains(where: { $0.absoluteString == key }) { continue }
            pending.append(url)
        }
    }

    private func flush() async {
        guard handler != nil, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        while let url = pending.first {
            pending.removeFirst()
            let key = url.absoluteString
            inFlight.insert(key)
            guard let handler else {
                inFlight.remove(key)
                pending.insert(url, at: 0)
                break
            }
            await Self.dispatch(url, through: handler)
            inFlight.remove(key)
        }
    }

    private static func dispatch(_ url: URL, through handler: ControlHandler) async {
        guard let action = FuturaTermURL.parse(url) else {
            logger.info("ignoring URL \(url.absoluteString, privacy: .public)")
            return
        }
        switch action {
        case let .open(path):
            let request = ControlRequest(
                command: "project.open",
                args: ControlArgs(path: path)
            )
            let response = await handler.handle(request)
            if let error = response.error {
                logger.error("URL project.open failed: \(error.message, privacy: .public)")
            }
        }
    }
}
