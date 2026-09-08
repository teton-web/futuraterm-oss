import Darwin
import Foundation

/// Sandboxed zmx socket-dir construction. Pure: no `setenv`, so Debug tests
/// can cover MAS path choice without compiling `APP_STORE`.
enum AppStoreZmxDir {
    /// Prefers `appSupport/zmx`. If that would overflow `sockaddr_un.sun_path`,
    /// falls back to `caches/zmx`, then a hashed subdirectory of `temporary`,
    /// then any `extraCandidates` (Darwin user temp, entitled config dir).
    /// Never last-resorts to global `/tmp` — the sandbox cannot use it.
    static func url(
        appSupport: URL,
        caches: URL,
        temporary: URL? = nil,
        extraCandidates: [URL] = []
    ) -> URL {
        let preferred = appSupport.appendingPathComponent("zmx", isDirectory: true)
        if fits(preferred) { return preferred }
        let cacheZmx = caches.appendingPathComponent("zmx", isDirectory: true)
        if fits(cacheZmx) { return cacheZmx }

        let name = shortName(for: appSupport)
        var parents: [URL] = []
        if let temporary { parents.append(temporary) }
        parents.append(contentsOf: extraCandidates)

        var shortestParent: URL?
        for parent in parents {
            let hashed = parent.appendingPathComponent(name, isDirectory: true)
            if fits(hashed) { return hashed }
            if let current = shortestParent {
                if parent.path.utf8.count < current.path.utf8.count {
                    shortestParent = parent
                }
            } else {
                shortestParent = parent
            }
        }
        if let shortestParent {
            return shortestParent.appendingPathComponent(name, isDirectory: true)
        }
        return appSupport.appendingPathComponent(name, isDirectory: true)
    }

    static func fits(_ dir: URL) -> Bool {
        ZmxSocketBudget.probe(env: ["ZMX_DIR": dir.path]) == nil
    }

    /// Stable 9-byte directory name (`z` + 8 hex) from the app-support path.
    static func shortName(for appSupport: URL) -> String {
        var hash: UInt64 = 5381
        for byte in appSupport.path.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "z%08x", UInt32(truncatingIfNeeded: hash))
    }

    /// Per-user Darwin temp (`/var/folders/…/T`). Often shorter than the MAS
    /// container `Data/tmp` path and still sandbox-writable.
    static func darwinUserTemporaryDirectory() -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        guard n > 1, n <= buf.count else { return nil }
        let bytes = buf.prefix(n - 1).map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Passwd-database home (`getpwuid`), not `$HOME` / `NSHomeDirectory()`.
    /// Under the App Store sandbox those two are the container `Data/` path
    /// (~71+ bytes), which overflows `sun_path` for `…/z########/<session>`.
    /// The MAS home-relative exception is the real `~/.config/futuraterm/`.
    static func unsandboxedHomeDirectory() -> String? {
        guard let pw = getpwuid(getuid()) else { return nil }
        let dir = String(cString: pw.pointee.pw_dir)
        return dir.isEmpty ? nil : dir
    }

    /// `~/.config/futuraterm` under the unsandboxed home — already in the MAS
    /// home-relative exception, and short enough that `dir/<session>` fits
    /// `sun_path` for typical usernames. `home:` is injectable for tests.
    static func entitledConfigDirectory(home: String? = nil) -> URL {
        let resolved = home ?? unsandboxedHomeDirectory() ?? ProjectPath.currentHome
        return URL(fileURLWithPath: resolved, isDirectory: true)
            .appendingPathComponent(".config/futuraterm", isDirectory: true)
    }
}
