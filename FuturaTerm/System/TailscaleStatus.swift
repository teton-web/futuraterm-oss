import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "TailscaleStatus")

struct TailscaleDevice: Equatable, Identifiable, Hashable {
    var id: String
    var hostName: String
    var dnsName: String
    var os: String
    var online: Bool
    var isSelf: Bool
    var tailscaleIPs: [String]
    var sshHost: String {
        TailscaleStatus.sshHost(dnsName: dnsName, ips: tailscaleIPs, hostName: hostName)
    }
}

enum TailscaleUnavailableReason: Equatable {
    case notInstalled
    case needsLogin
    case stopped
    case error(String)
}

enum TailscaleSnapshot: Equatable {
    case unavailable(TailscaleUnavailableReason)
    case ready(devices: [TailscaleDevice], selfHostName: String?)
}

enum TailscaleStatus {
    typealias Runner = @Sendable (String, [String]) async -> (status: Int32, stdout: Data)?

    static let statusArguments = ["status", "--json"]

    static let applicationsCLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    static let usrLocalCLI = "/usr/local/bin/tailscale"
    static let homebrewCLI = "/opt/homebrew/bin/tailscale"

    /// First existing candidate: PATH dirs, then the app bundle, then Homebrew/usr-local.
    static func locateCLI(
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        pathEnv: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String? {
        var candidates: [String] = []
        if let pathEnv {
            for dir in pathEnv.split(separator: ":") {
                let trimmed = dir.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                candidates.append((trimmed as NSString).appendingPathComponent("tailscale"))
            }
        }
        candidates.append(contentsOf: [applicationsCLI, usrLocalCLI, homebrewCLI])
        return candidates.first { fileExists($0) }
    }

    static func parse(_ data: Data) -> TailscaleSnapshot {
        guard !data.isEmpty else {
            return .unavailable(.error("Tailscale status was empty"))
        }
        let decoded: StatusDTO
        do {
            decoded = try JSONDecoder().decode(StatusDTO.self, from: data)
        } catch {
            return .unavailable(.error("Tailscale status was unreadable"))
        }

        let backend = decoded.backendState ?? ""
        switch backend {
        case "NeedsLogin",
             "NeedsMachineAuth":
            logger.info("backend \(backend, privacy: .public) devices 0")
            return .unavailable(.needsLogin)
        case "Stopped",
             "NoState":
            logger.info("backend \(backend, privacy: .public) devices 0")
            return .unavailable(.stopped)
        case "Starting",
             "Running":
            return readySnapshot(from: decoded, backend: backend)
        default:
            if decoded.peer == nil, decoded.selfNode == nil {
                logger.info("backend unknown devices 0")
                return .unavailable(.error("Tailscale status was unreadable"))
            }
            return readySnapshot(from: decoded, backend: backend.isEmpty ? "unknown" : backend)
        }
    }

    static func probe(
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        pathEnv: String? = ProcessInfo.processInfo.environment["PATH"],
        run: Runner? = nil
    ) async -> TailscaleSnapshot {
        guard let executable = locateCLI(fileExists: fileExists, pathEnv: pathEnv) else {
            return .unavailable(.notInstalled)
        }
        let runner = run ?? liveRun
        guard let result = await runner(executable, statusArguments) else {
            return .unavailable(.error("Tailscale status timed out"))
        }
        if result.stdout.isEmpty {
            return .unavailable(.error("Tailscale status was empty"))
        }
        if result.status != 0 {
            let snapshot = parse(result.stdout)
            if case .unavailable(.error) = snapshot {
                return .unavailable(.error("Tailscale status failed"))
            }
            return snapshot
        }
        return parse(result.stdout)
    }

    // MARK: - Private

    private static func readySnapshot(from decoded: StatusDTO, backend: String) -> TailscaleSnapshot {
        let selfID = decoded.selfNode?.id
        let selfHostName = decoded.selfNode.flatMap { node in
            let name = node.hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
        var devices: [TailscaleDevice] = []
        if let peers = decoded.peer {
            for node in peers.values {
                guard let device = device(from: node, selfID: selfID), !device.isSelf else { continue }
                devices.append(device)
            }
        }
        devices.sort { a, b in
            if a.online != b.online {
                return a.online && !b.online
            }
            return a.hostName.localizedStandardCompare(b.hostName) == .orderedAscending
        }
        logger.info("backend \(backend, privacy: .public) devices \(devices.count, privacy: .public)")
        return .ready(devices: devices, selfHostName: selfHostName)
    }

    private static func device(from node: NodeDTO, selfID: String?) -> TailscaleDevice? {
        let id = node.id ?? ""
        let hostName = node.hostName ?? ""
        guard !id.isEmpty || !hostName.isEmpty else { return nil }
        let dnsName = stripTrailingDots(node.dnsName ?? "")
        let ips = node.tailscaleIPs ?? []
        let isSelf = selfID != nil && id == selfID
        return TailscaleDevice(
            id: id,
            hostName: hostName,
            dnsName: dnsName,
            os: node.os ?? "",
            online: node.online ?? false,
            isSelf: isSelf,
            tailscaleIPs: ips
        )
    }

    static func sshHost(dnsName: String, ips: [String], hostName: String) -> String {
        if !dnsName.isEmpty {
            return dnsName
        }
        if let ip = ips.first(where: isIPv4CGNAT) {
            return ip
        }
        return hostName
    }

    private static func isIPv4CGNAT(_ ip: String) -> Bool {
        ip.hasPrefix("100.") && !ip.contains(":")
    }

    private static func stripTrailingDots(_ name: String) -> String {
        var result = name
        while result.hasSuffix(".") {
            result.removeLast()
        }
        return result
    }

    nonisolated private static func liveRun(
        executable: String, arguments: [String]
    ) async -> (status: Int32, stdout: Data)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runProcess(executable: executable, arguments: arguments))
            }
        }
    }

    /// Drain stdout while the child runs. A blocking `readToEnd()` on a GCD
    /// thread can fail to consume the pipe, so `tailscale status --json` past
    /// ~64KB stalls on write until the watchdog SIGTERMs it. The
    /// `readabilityHandler` is wired before `run()` so a fast child cannot
    /// close the pipe before the EOF waiter is armed.
    nonisolated static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 5
    ) -> (status: Int32, stdout: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

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
            logger.warning("\(executable, privacy: .public) failed to spawn: \(error, privacy: .public)")
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        process.waitUntilExit()
        _ = stdoutEOF.wait(timeout: .now() + .seconds(1))
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        let out = stdoutBuffer.withLock { $0 }
        if process.terminationReason == .uncaughtSignal {
            return nil
        }
        return (process.terminationStatus, out)
    }
}

private struct StatusDTO: Decodable {
    var backendState: String?
    var selfNode: NodeDTO?
    var peer: [String: NodeDTO]?

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case selfNode = "Self"
        case peer = "Peer"
    }
}

private struct NodeDTO: Decodable {
    var id: String?
    var hostName: String?
    var dnsName: String?
    var os: String?
    var online: Bool?
    var tailscaleIPs: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case hostName = "HostName"
        case dnsName = "DNSName"
        case os = "OS"
        case online = "Online"
        case tailscaleIPs = "TailscaleIPs"
    }
}
