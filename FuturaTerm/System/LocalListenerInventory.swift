import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "LocalListenerInventory")

/// Pure join of `lsof -Fpcun` TCP LISTEN sockets onto cwd/argv and sidebar projects.
/// Process I/O is injected via `probe`'s `run` (and cwd/argv closures).
enum LocalListenerInventory {
    static let lsofExecutable = "/usr/sbin/lsof"
    static let lsofArguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcun"]

    struct Socket: Equatable {
        var pid: pid_t
        var command: String
        var uid: uid_t
        var address: String
        var port: Int
    }

    struct Row: Equatable, Identifiable {
        var id: String
        var pid: pid_t
        var command: String
        var port: Int
        var address: String
        var displayURL: String
        var cwd: String?
        var argvSummary: String?
        var projectName: String?
        var projectID: UUID?
        /// Kernel start time at snapshot; kill requires this pid still has it.
        var startDate: Date?
    }

    enum Snapshot: Equatable {
        case unavailable
        case ready([Row])
    }

    static let systemDenylist: Set<String> = [
        "launchd",
        "kernel_task",
        "syslogd",
        "mdnsresponder",
        "cupsd",
        "controlcenter",
        "rapportd",
        "sharingd",
        "identityservicesd",
        "bluetoothd",
        "windowserver",
        "loginwindow",
        "cfprefsd",
        "distnoted",
        "notifyd",
        "configd",
        "airportd",
        "coreaudiod",
        "cloudd",
        "ntpd",
        "timed",
        "securityd",
        "trustd",
        "runningboardd",
        "usereventagent",
        "filecoordinationd",
        "fseventsd",
        "nsurlsessiond",
        "imagend",
        "bird",
    ]

    static func parseLsofF(_ data: Data) -> [Socket] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var sockets: [Socket] = []
        var pid: pid_t?
        var command = ""
        var uid: uid_t = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            switch first {
            case "p":
                pid = pid_t(value)
                command = ""
                uid = 0
            case "c":
                command = value
            case "u":
                uid = uid_t(value) ?? 0
            case "n":
                guard let pid, let parsed = parseName(value) else { continue }
                sockets.append(Socket(
                    pid: pid,
                    command: command,
                    uid: uid,
                    address: parsed.address,
                    port: parsed.port
                ))
            default:
                continue
            }
        }
        return sockets
    }

    static func shouldInclude(_ socket: Socket, uid: uid_t, selfPid: pid_t) -> Bool {
        guard socket.uid == uid else { return false }
        guard socket.pid != selfPid else { return false }
        if isLoopback(socket.address) {
            return true
        }
        guard isWildcard(socket.address) else { return false }
        guard socket.port >= 1024 else { return false }
        let comm = (socket.command as NSString).lastPathComponent.lowercased()
        return !systemDenylist.contains(comm)
    }

    // swiftlint:disable:next function_parameter_count
    static func rows(
        sockets: [Socket],
        uid: uid_t,
        selfPid: pid_t,
        cwd: (pid_t) -> String?,
        argv: (pid_t) -> [String]?,
        projects: [Project],
        startDate: (pid_t) -> Date? = { ProcessInspector.startDate(pid: $0) }
    ) -> [Row] {
        let included = sockets.filter { shouldInclude($0, uid: uid, selfPid: selfPid) }
        let preferred = dedupe(included)
        let mapped = preferred.map { socket in
            row(
                for: socket,
                cwd: cwd(socket.pid),
                argv: argv(socket.pid),
                projects: projects,
                startDate: startDate(socket.pid)
            )
        }
        return mapped.sorted(by: rowSort)
    }

    @MainActor
    static func probe(
        run: ((String, [String]) async -> (status: Int32, stdout: Data)?)? = nil,
        uid: uid_t,
        selfPid: pid_t,
        cwd: (pid_t) -> String?,
        argv: (pid_t) -> [String]?,
        projects: [Project]
    ) async -> Snapshot {
        let runner = run ?? liveRun
        guard let result = await runner(lsofExecutable, lsofArguments) else {
            return .unavailable
        }
        if result.status != 0, result.stdout.isEmpty {
            logger.info("local listeners: \(0, privacy: .public)")
            return .ready([])
        }
        let sockets = parseLsofF(result.stdout)
        let list = rows(
            sockets: sockets,
            uid: uid,
            selfPid: selfPid,
            cwd: cwd,
            argv: argv,
            projects: projects,
            startDate: { ProcessInspector.startDate(pid: $0) }
        )
        logger.info("local listeners: \(list.count, privacy: .public)")
        return .ready(list)
    }

    /// Hop off the caller (typically MainActor) before blocking on `lsof`.
    nonisolated static func liveRun(
        executable: String, arguments: [String]
    ) async -> (status: Int32, stdout: Data)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runLsof(executable: executable, arguments: arguments))
            }
        }
    }

    /// Bounded `lsof` spawn. Nil on missing binary, spawn failure, or timeout.
    nonisolated static func runLsof(
        executable: String = lsofExecutable,
        arguments: [String] = lsofArguments
    ) -> (status: Int32, stdout: Data)? {
        if Preferences.isTestRun {
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        // Wire the drain before spawn so a fast/empty `lsof` cannot close
        // stdout before the EOF waiter is armed.
        let stdoutEOF = DispatchSemaphore(value: 0)
        let stdoutBuffer = OSAllocatedUnfairLock(initialState: Data())
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                stdoutEOF.signal()
                return
            }
            stdoutBuffer.withLock { $0.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            logger.warning("lsof failed to spawn: \(error, privacy: .public)")
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = DispatchWorkItem {
            timedOut.withLock { $0 = true }
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5), execute: watchdog)
        defer { watchdog.cancel() }

        process.waitUntilExit()
        _ = stdoutEOF.wait(timeout: .now() + .seconds(1))
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        let out = stdoutBuffer.withLock { $0 }
        if timedOut.withLock({ $0 }) {
            return nil
        }
        return (process.terminationStatus, out)
    }

    private static func parseName(_ name: String) -> (address: String, port: Int)? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        let host = String(name[..<colon])
        let portText = String(name[name.index(after: colon)...])
        guard let port = Int(portText) else { return nil }
        var address = host
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        return (address, port)
    }

    private static func isLoopback(_ address: String) -> Bool {
        if address == "::1" || address.lowercased() == "localhost" {
            return true
        }
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { Int($0).map { (0 ... 255).contains($0) } ?? false }
    }

    private static func isWildcard(_ address: String) -> Bool {
        address == "*" || address == "0.0.0.0" || address == "::"
    }

    private static func dedupe(_ sockets: [Socket]) -> [Socket] {
        var best: [String: Socket] = [:]
        for socket in sockets {
            let key = "\(socket.pid):\(socket.port)"
            if let existing = best[key] {
                if isLoopback(socket.address), !isLoopback(existing.address) {
                    best[key] = socket
                }
            } else {
                best[key] = socket
            }
        }
        return Array(best.values)
    }

    private static func row(
        for socket: Socket,
        cwd: String?,
        argv: [String]?,
        projects: [Project],
        startDate: Date?
    ) -> Row {
        let match = matchingProject(cwd: cwd, projects: projects)
        return Row(
            id: "\(socket.pid):\(socket.port)",
            pid: socket.pid,
            command: socket.command,
            port: socket.port,
            address: socket.address,
            displayURL: "http://127.0.0.1:\(socket.port)",
            cwd: cwd,
            argvSummary: argvSummary(argv, command: socket.command),
            projectName: match?.name,
            projectID: match?.id,
            startDate: startDate
        )
    }

    private static func argvSummary(_ argv: [String]?, command: String) -> String? {
        guard let argv, !argv.isEmpty else { return nil }
        if argv.count == 1, (argv[0] as NSString).lastPathComponent == (command as NSString).lastPathComponent {
            return nil
        }
        var joined = argv.joined(separator: " ")
        if joined.count > 80 {
            joined = String(joined.prefix(80))
        }
        return joined
    }

    private static func matchingProject(cwd: String?, projects: [Project]) -> Project? {
        guard let cwd else { return nil }
        let eligible = projects.filter { $0.id != PinnedTabs.projectID && !$0.isRemote }
        let hits = eligible.filter { projectCovers(project: $0, cwd: cwd) }
        guard !hits.isEmpty else { return nil }
        func root(_ project: Project) -> String {
            ProjectPath.resolvedLocal(project.path)
        }
        let deepestLength = hits.map { root($0).count }.max() ?? 0
        let deepest = hits.filter { root($0).count == deepestLength }
        guard deepest.count == 1 else { return nil }
        return deepest[0]
    }

    /// Kernel cwd is realpath (`/private/tmp`, symlink targets); `project.path` is not.
    private static func projectCovers(project: Project, cwd: String) -> Bool {
        let root = ProjectPath.resolvedLocal(project.path)
        let child = ProjectPath.resolvedLocal(cwd)
        if child == root {
            return true
        }
        if root == "/" {
            return child.hasPrefix("/")
        }
        return child.hasPrefix(root + "/")
    }

    private static func rowSort(_ a: Row, _ b: Row) -> Bool {
        if a.port != b.port {
            return a.port < b.port
        }
        return a.command.localizedStandardCompare(b.command) == .orderedAscending
    }
}
