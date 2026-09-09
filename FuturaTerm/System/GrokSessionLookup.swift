import Foundation

/// On-disk Grok session chrome: `~/.grok/sessions/<encoded-cwd>/<uuid>/summary.json`.
struct GrokSessionChrome: Equatable {
    var sessionID: String
    var createdAt: Date
    var updatedAt: Date?
    var title: String?
}

/// Pure matching + JSON parse for Grok session start times. Process I/O lives
/// in `resolve(pid:cwd:grokHome:)` so tests can exercise the path/JSON seams
/// without a live `grok` process.
enum GrokSessionLookup {
    /// RFC 3986 unreserved — matches grok's `urlencoding::encode` for cwd dirs.
    private static let rfc3986Unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Directory that holds `summary.json` for one session.
    struct Location: Equatable {
        var sessionID: String
        var directory: URL
    }

    /// Map a Grok pid onto session chrome. Prefers an open file under
    /// `{grokHome}/sessions/…/<uuid>/` (Grok keeps `events.jsonl` open). Falls
    /// back to a unique UUIDv7 in that cwd whose timestamp matches process
    /// start — never guesses among several.
    static func resolve(pid: pid_t, cwd: String?, grokHome: String) -> GrokSessionChrome? {
        let paths = ProcessInspector.vnodePaths(pid: pid)
        if let location = location(inOpenPaths: paths, grokHome: grokHome) {
            return loadChrome(at: location)
        }
        guard let cwd, let start = ProcessInspector.startDate(pid: pid),
              let sessionID = uniqueSessionID(
                  cwd: cwd,
                  matchingStart: start,
                  grokHome: grokHome
              )
        else { return nil }
        return loadChrome(sessionID: sessionID, cwd: cwd, grokHome: grokHome)
    }

    /// `{grokHome}/sessions/<cwd-dir>/<uuid>/…` → that uuid + directory.
    static func location(inOpenPaths paths: [String], grokHome: String) -> Location? {
        let home = URL(fileURLWithPath: grokHome, isDirectory: true)
            .standardizedFileURL.path
        let marker = "/sessions/"
        for path in paths {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard standardized.hasPrefix(home),
                  let range = standardized.range(of: marker)
            else { continue }
            let rest = standardized[range.upperBound...]
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let sessionID = String(parts[1])
            guard UUID(uuidString: sessionID) != nil else { continue }
            let directory = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(String(parts[0]), isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            return Location(sessionID: sessionID, directory: directory)
        }
        return nil
    }

    static func encodeCwd(_ cwd: String) -> String {
        let trimmed = normalizedCwd(cwd)
        return trimmed.addingPercentEncoding(withAllowedCharacters: rfc3986Unreserved) ?? trimmed
    }

    static func normalizedCwd(_ cwd: String) -> String {
        if cwd.count > 1, cwd.hasSuffix("/") {
            return String(cwd.dropLast())
        }
        return cwd
    }

    static func parseSummary(_ data: Data, sessionID: String) -> GrokSessionChrome? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let created = string(root["created_at"]).flatMap(GrokRFC3339.parse)
            ?? GrokSessionAge.createdAt(fromSessionID: sessionID)
        guard let created else { return nil }
        let updated = string(root["updated_at"]).flatMap(GrokRFC3339.parse)
            ?? string(root["last_active_at"]).flatMap(GrokRFC3339.parse)
        let title = string(root["generated_title"])
        return GrokSessionChrome(
            sessionID: sessionID,
            createdAt: created,
            updatedAt: updated,
            title: title
        )
    }

    static func loadChrome(at location: Location) -> GrokSessionChrome? {
        let url = location.directory.appendingPathComponent("summary.json")
        if let data = try? Data(contentsOf: url),
           let chrome = parseSummary(data, sessionID: location.sessionID)
        {
            return chrome
        }
        guard let created = GrokSessionAge.createdAt(fromSessionID: location.sessionID) else {
            return nil
        }
        return GrokSessionChrome(sessionID: location.sessionID, createdAt: created)
    }

    static func loadChrome(sessionID: String, cwd: String, grokHome: String) -> GrokSessionChrome? {
        let directory = URL(fileURLWithPath: grokHome, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encodeCwd(cwd), isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        return loadChrome(at: Location(sessionID: sessionID, directory: directory))
    }

    /// Unique UUIDv7 in the cwd's session dir whose embedded timestamp is
    /// within 5s of process start. Several matches → nil (don't guess).
    static func uniqueSessionID(
        cwd: String,
        matchingStart start: Date,
        grokHome: String,
        window: TimeInterval = 5
    ) -> String? {
        let dir = URL(fileURLWithPath: grokHome, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encodeCwd(cwd), isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return nil
        }
        var match: String?
        for name in names {
            guard UUID(uuidString: name) != nil,
                  let created = GrokSessionAge.createdAt(fromSessionID: name),
                  abs(created.timeIntervalSince(start)) < window
            else { continue }
            if match != nil { return nil }
            match = name
        }
        return match
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
