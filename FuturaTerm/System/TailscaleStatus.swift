import Darwin
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

    var devices: [TailscaleDevice] {
        switch self {
        case let .ready(devices, _): devices
        case .unavailable: []
        }
    }
}

struct TailscaleLocalAPIProof: Equatable {
    var port: Int
    var token: String
    var path: String
}

enum TailscaleStatus {
    typealias Runner = @Sendable (String, [String]) async -> (status: Int32, stdout: Data)?
    typealias ProofFetcher = @Sendable (Int, String) -> Data?

    static let statusArguments = ["status", "--json"]
    static let localAPIStatusPath = "/localapi/v0/status"

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
        run: Runner? = nil,
        home: String = ProjectPath.currentHome,
        contentsOfDirectory: @escaping @Sendable (String) -> [String] = { dir in
            (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        },
        fetchProof: ProofFetcher? = nil
    ) async -> TailscaleSnapshot {
        let proofs = discoverLocalAPIProofs(home: home, contentsOfDirectory: contentsOfDirectory)
        for proof in proofs {
            let data: Data? = if let fetchProof {
                fetchProof(proof.port, proof.token)
            } else {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(
                            returning: liveFetchLocalAPI(port: proof.port, token: proof.token)
                        )
                    }
                }
            }
            if let snapshot = snapshot(fromLocalAPI: data, port: proof.port) {
                return snapshot
            }
        }

        guard let executable = locateCLI(fileExists: fileExists, pathEnv: pathEnv) else {
            return proofs.isEmpty ? .unavailable(.notInstalled) : .unavailable(.stopped)
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

    /// `sameuserproof-<port>-<token>` — token lives in the filename, not the file.
    static func parseSameUserProofName(_ name: String) -> (port: Int, token: String)? {
        let prefix = "sameuserproof-"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let portPart = rest[..<dash]
        let token = rest[rest.index(after: dash)...]
        guard let port = Int(portPart), (1 ... 65535).contains(port), !token.isEmpty else {
            return nil
        }
        return (port, String(token))
    }

    /// Tailscale's Mac GUI publishes LocalAPI on loopback and drops a
    /// `sameuserproof-<port>-<token>` file in its group container. Reading
    /// that HTTP endpoint does not exec Tailscale.app — `status --json` via
    /// the GUI binary fails from other apps (empty stdout / CLIError 3).
    static func discoverLocalAPIProofs(
        home: String,
        contentsOfDirectory: (String) -> [String]
    ) -> [TailscaleLocalAPIProof] {
        let groupRoot = (home as NSString).appendingPathComponent("Library/Group Containers")
        var proofs: [TailscaleLocalAPIProof] = []
        for group in contentsOfDirectory(groupRoot) {
            let base = (group as NSString).lastPathComponent
            guard base.contains("io.tailscale.ipn") else { continue }
            let dir = (groupRoot as NSString).appendingPathComponent(base)
            for file in contentsOfDirectory(dir) {
                let name = (file as NSString).lastPathComponent
                guard let parsed = parseSameUserProofName(name) else { continue }
                proofs.append(
                    TailscaleLocalAPIProof(
                        port: parsed.port,
                        token: parsed.token,
                        path: (dir as NSString).appendingPathComponent(name)
                    )
                )
            }
        }
        return proofs
    }

    /// Split an HTTP/1 response into a 200 body. Nil while headers/body are
    /// still arriving (`connectionClosed: false`) or on any non-200.
    static func httpResponseBody(_ data: Data, connectionClosed: Bool = true) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        let header = data[..<range.lowerBound]
        guard let headerText = String(data: header, encoding: .utf8) else { return nil }
        let firstLine = headerText.prefix { $0 != "\r" && $0 != "\n" }
        let parts = firstLine.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, parts[1] == "200" else { return nil }
        let remainder = Data(data[range.upperBound...])
        let contentLength = headerText.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "content-length:"
            guard text.lowercased().hasPrefix(prefix) else { return nil }
            return Int(text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
        }.first
        if let contentLength {
            guard remainder.count >= contentLength else { return nil }
            return remainder.prefix(contentLength)
        }
        // LocalAPI HTTP/1.0 often omits Content-Length and holds the
        // socket open. A complete JSON object is the whole body.
        if (try? JSONSerialization.jsonObject(with: remainder)) != nil {
            return remainder
        }
        return connectionClosed ? remainder : nil
    }

    // MARK: - Private

    private static func snapshot(fromLocalAPI data: Data?, port: Int) -> TailscaleSnapshot? {
        guard let data, !data.isEmpty else { return nil }
        let snapshot = parse(data)
        if case .unavailable(.error) = snapshot {
            return nil
        }
        logger.info("localapi port \(port, privacy: .public)")
        return snapshot
    }

    /// Loopback GET of `/localapi/v0/status`. POSIX on purpose: URLSession
    /// is subject to ATS, and this must work from a sandboxed-looking GUI
    /// without a plist exception.
    nonisolated static func liveFetchLocalAPI(
        port: Int,
        token: String,
        timeoutSeconds: Int = 2
    ) -> Data? {
        guard let port16 = UInt16(exactly: port) else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port16.bigEndian)
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

        // SO_RCVTIMEO / SO_SNDTIMEO do not bound connect() on Darwin. A stale
        // LocalAPI port can sit in SYN until TCP gives up (~75s), which hung
        // the hosted unit suite on a live sameuserproof.
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return nil }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }

        let connected: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeoutSeconds) * 1000)
            guard ready > 0 else { return nil }
            var soError: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen) == 0,
                  soError == 0
            else { return nil }
        }
        guard fcntl(fd, F_SETFL, flags) == 0 else { return nil }

        let auth = Data((":" + token).utf8).base64EncodedString()
        // Host MUST include the port. Tailscale LocalAPI 403s
        // `invalid localapi request` on `Host: 127.0.0.1` without it.
        // HTTP/1.0 avoids chunked Transfer-Encoding so the body is raw JSON.
        let request =
            "GET \(localAPIStatusPath) HTTP/1.0\r\n"
                + "Host: 127.0.0.1:\(port)\r\n"
                + "Authorization: Basic \(auth)\r\n"
                + "Connection: close\r\n"
                + "\r\n"
        let requestData = Data(request.utf8)
        let sent = requestData.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return Darwin.send(fd, base, raw.count, 0)
        }
        guard sent == requestData.count else { return nil }

        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            if n <= 0 {
                return httpResponseBody(collected, connectionClosed: true)
            }
            collected.append(contentsOf: buffer[0 ..< n])
            if collected.count > 8 * 1024 * 1024 { return nil }
            if let body = httpResponseBody(collected, connectionClosed: false) {
                return body
            }
        }
    }

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
