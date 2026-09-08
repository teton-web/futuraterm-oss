import Foundation
@testable import FuturaTerm
import Testing

struct TailscaleStatusTests {
    @Test
    func running_fixture_excludes_self_and_strips_dns() throws {
        let json = """
        {
          "BackendState": "Running",
          "Self": {
            "ID": "self1",
            "HostName": "macbook",
            "DNSName": "macbook.tailnet.ts.net.",
            "OS": "macOS",
            "Online": true,
            "TailscaleIPs": ["100.64.0.1"]
          },
          "Peer": {
            "n1": {
              "ID": "peer1",
              "HostName": "box",
              "DNSName": "box.tailnet.ts.net.",
              "OS": "linux",
              "Online": true,
              "TailscaleIPs": ["100.64.0.2"]
            },
            "n2": {
              "ID": "peer2",
              "HostName": "offline-box",
              "DNSName": "offline-box.tailnet.ts.net.",
              "OS": "linux",
              "Online": false,
              "TailscaleIPs": ["100.64.0.3"]
            },
            "nself": {
              "ID": "self1",
              "HostName": "macbook",
              "DNSName": "macbook.tailnet.ts.net.",
              "OS": "macOS",
              "Online": true,
              "TailscaleIPs": ["100.64.0.1"]
            }
          }
        }
        """
        let snapshot = TailscaleStatus.parse(Data(json.utf8))
        guard case let .ready(devices, selfHostName) = snapshot else {
            Issue.record("expected ready, got \(snapshot)")
            return
        }
        #expect(devices.count == 2)
        #expect(selfHostName == "macbook")
        #expect(!devices.contains(where: { $0.id == "self1" || $0.isSelf }))
        let box = try #require(devices.first { $0.hostName == "box" })
        #expect(box.sshHost == "box.tailnet.ts.net")
        #expect(box.dnsName == "box.tailnet.ts.net")
        #expect(box.online)
        #expect(!box.sshHost.contains("@"))
        let composed = try #require(ProjectPath.composeRemote(host: box.sshHost, directory: "~"))
        #expect(composed == "box.tailnet.ts.net:~")
        let offline = try #require(devices.first { $0.hostName == "offline-box" })
        #expect(!offline.online)
        #expect(devices[0].online)
        #expect(!devices[1].online)
    }

    @Test
    func ip_fallback_skips_ipv6() throws {
        let json = """
        {
          "BackendState": "Running",
          "Self": { "ID": "self1", "HostName": "me" },
          "Peer": {
            "n1": {
              "ID": "peer1",
              "HostName": "cg-nat",
              "DNSName": "",
              "OS": "linux",
              "Online": true,
              "TailscaleIPs": ["fd7a::1", "100.64.1.2"]
            }
          }
        }
        """
        let snapshot = TailscaleStatus.parse(Data(json.utf8))
        guard case let .ready(devices, _) = snapshot else {
            Issue.record("expected ready, got \(snapshot)")
            return
        }
        let device = try #require(devices.first)
        #expect(device.sshHost == "100.64.1.2")
        #expect(!device.sshHost.contains(":"))
        #expect(!device.sshHost.contains("@"))
        let composed = try #require(ProjectPath.composeRemote(host: device.sshHost, directory: "~"))
        #expect(composed == "100.64.1.2:~")
    }

    @Test
    func needs_login_even_with_peers() {
        let json = """
        {
          "BackendState": "NeedsLogin",
          "Peer": {
            "n1": { "ID": "p", "HostName": "box", "DNSName": "box.ts.net.", "Online": true }
          }
        }
        """
        let snapshot = TailscaleStatus.parse(Data(json.utf8))
        #expect(snapshot == .unavailable(.needsLogin))
    }

    @Test
    func stopped_maps_to_stopped() {
        let json = #"{"BackendState":"Stopped"}"#
        #expect(TailscaleStatus.parse(Data(json.utf8)) == .unavailable(.stopped))
    }

    @Test
    func empty_and_invalid_json_are_errors() {
        let empty = TailscaleStatus.parse(Data())
        guard case .unavailable(.error) = empty else {
            Issue.record("empty should be error")
            return
        }
        let truncated = TailscaleStatus.parse(Data("{".utf8))
        guard case .unavailable(.error) = truncated else {
            Issue.record("truncated should be error")
            return
        }
    }

    @Test
    func locateCLI_path_wins_over_applications() {
        let pathHit = "/tmp/bin/tailscale"
        let found = TailscaleStatus.locateCLI(
            fileExists: { $0 == pathHit || $0 == TailscaleStatus.applicationsCLI },
            pathEnv: "/tmp/bin:/usr/bin"
        )
        #expect(found == pathHit)
    }

    @Test
    func locateCLI_applications_when_path_empty() {
        let found = TailscaleStatus.locateCLI(
            fileExists: { $0 == TailscaleStatus.applicationsCLI },
            pathEnv: "/usr/bin"
        )
        #expect(found == TailscaleStatus.applicationsCLI)
    }

    @Test
    func locateCLI_nil_when_nothing_exists() {
        let found = TailscaleStatus.locateCLI(fileExists: { _ in false }, pathEnv: "/usr/bin")
        #expect(found == nil)
    }

    @Test
    func probe_stub_needs_login_json() async {
        let json = Data(#"{"BackendState":"NeedsLogin"}"#.utf8)
        let snapshot = await TailscaleStatus.probe(
            fileExists: { $0.hasSuffix("/tailscale") },
            pathEnv: "/opt/homebrew/bin",
            run: { executable, arguments in
                #expect(arguments == TailscaleStatus.statusArguments)
                #expect(executable.hasSuffix("tailscale"))
                return (1, json)
            },
            contentsOfDirectory: { _ in [] }
        )
        #expect(snapshot == .unavailable(.needsLogin))
    }

    @Test
    func probe_nil_cli_is_not_installed() async {
        let snapshot = await TailscaleStatus.probe(
            fileExists: { _ in false },
            pathEnv: "/usr/bin",
            run: { _, _ in
                Issue.record("runner must not spawn")
                return (0, Data())
            },
            contentsOfDirectory: { _ in [] }
        )
        #expect(snapshot == .unavailable(.notInstalled))
    }

    @Test
    func parseSameUserProofName_reads_port_and_token() {
        let parsed = TailscaleStatus.parseSameUserProofName(
            "sameuserproof-49173-91cd953755e1d798f841"
        )
        #expect(parsed?.port == 49173)
        #expect(parsed?.token == "91cd953755e1d798f841")
        #expect(TailscaleStatus.parseSameUserProofName("sameuserproof-nope") == nil)
        #expect(TailscaleStatus.parseSameUserProofName("audit-log") == nil)
        #expect(TailscaleStatus.parseSameUserProofName("sameuserproof-0-abc") == nil)
    }

    @Test
    func discoverLocalAPIProofs_skips_unrelated_containers() {
        let home = "/tmp/ft-home"
        let listings: [String: [String]] = [
            "/tmp/ft-home/Library/Group Containers": [
                "W5364U7YZB.group.io.tailscale.ipn.macos",
                "com.apple.osx-tailspin",
            ],
            "/tmp/ft-home/Library/Group Containers/W5364U7YZB.group.io.tailscale.ipn.macos": [
                "sameuserproof-49173-abc",
                "ipn.log..log1.txt",
            ],
            "/tmp/ft-home/Library/Group Containers/com.apple.osx-tailspin": [
                "sameuserproof-1-nope",
            ],
        ]
        let proofs = TailscaleStatus.discoverLocalAPIProofs(
            home: home,
            contentsOfDirectory: { listings[$0] ?? [] }
        )
        #expect(proofs.count == 1)
        #expect(proofs[0].port == 49173)
        #expect(proofs[0].token == "abc")
        #expect(proofs[0].path.hasSuffix("sameuserproof-49173-abc"))
    }

    @Test
    func httpResponseBody_requires_200() {
        let ok = Data("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        #expect(TailscaleStatus.httpResponseBody(ok) == Data("{}".utf8))
        let deny = Data("HTTP/1.0 401 Unauthorized\r\n\r\nbad password\n".utf8)
        #expect(TailscaleStatus.httpResponseBody(deny) == nil)
        #expect(TailscaleStatus.httpResponseBody(Data("not http".utf8)) == nil)
        let partial = Data("HTTP/1.0 200 OK\r\nContent-Length: 10\r\n\r\n{}".utf8)
        #expect(TailscaleStatus.httpResponseBody(partial, connectionClosed: false) == nil)
        let extra = Data("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n{}trailing".utf8)
        #expect(TailscaleStatus.httpResponseBody(extra, connectionClosed: false) == Data("{}".utf8))
        let jsonNoLength = Data("HTTP/1.0 200 OK\r\n\r\n{\"BackendState\":\"Running\"}".utf8)
        #expect(
            TailscaleStatus.httpResponseBody(jsonNoLength, connectionClosed: false)
                == Data("{\"BackendState\":\"Running\"}".utf8)
        )
        let incompleteJSON = Data("HTTP/1.0 200 OK\r\n\r\n{\"Backend".utf8)
        #expect(TailscaleStatus.httpResponseBody(incompleteJSON, connectionClosed: false) == nil)
    }

    @Test
    func probe_prefers_localapi_over_cli() async {
        let json = Data(
            (
                #"{"BackendState":"Running","Self":{"ID":"s","HostName":"me"},"#
                    + #""Peer":{"n":{"ID":"p","HostName":"box","DNSName":"box.ts.net.","Online":true}}}"#
            ).utf8
        )
        let snapshot = await TailscaleStatus.probe(
            fileExists: { _ in true },
            pathEnv: "/opt/homebrew/bin",
            run: { _, _ in
                Issue.record("CLI must not run when LocalAPI answers")
                return (0, Data())
            },
            home: "/tmp/ft-home",
            contentsOfDirectory: { dir in
                if dir.hasSuffix("Group Containers") {
                    return ["W5364U7YZB.group.io.tailscale.ipn.macos"]
                }
                if dir.contains("io.tailscale.ipn") {
                    return ["sameuserproof-49173-tok"]
                }
                return []
            },
            fetchProof: { port, token in
                #expect(port == 49173)
                #expect(token == "tok")
                return json
            }
        )
        guard case let .ready(devices, _) = snapshot else {
            Issue.record("expected ready, got \(snapshot)")
            return
        }
        #expect(devices.contains { $0.hostName == "box" })
    }

    @Test
    func probe_falls_back_to_cli_when_localapi_misses() async {
        let json = Data(#"{"BackendState":"NeedsLogin"}"#.utf8)
        let snapshot = await TailscaleStatus.probe(
            fileExists: { $0.hasSuffix("/tailscale") },
            pathEnv: "/opt/homebrew/bin",
            run: { _, _ in (1, json) },
            home: "/tmp/ft-home",
            contentsOfDirectory: { dir in
                if dir.hasSuffix("Group Containers") {
                    return ["W5364U7YZB.group.io.tailscale.ipn.macos"]
                }
                if dir.contains("io.tailscale.ipn") {
                    return ["sameuserproof-9-tok"]
                }
                return []
            },
            fetchProof: { _, _ in nil }
        )
        #expect(snapshot == .unavailable(.needsLogin))
    }

    @Test
    func probe_proof_without_cli_is_stopped() async {
        let snapshot = await TailscaleStatus.probe(
            fileExists: { _ in false },
            pathEnv: "/usr/bin",
            run: { _, _ in
                Issue.record("runner must not spawn")
                return (0, Data())
            },
            home: "/tmp/ft-home",
            contentsOfDirectory: { dir in
                if dir.hasSuffix("Group Containers") {
                    return ["W5364U7YZB.group.io.tailscale.ipn.macos"]
                }
                if dir.contains("io.tailscale.ipn") {
                    return ["sameuserproof-9-tok"]
                }
                return []
            },
            fetchProof: { _, _ in nil }
        )
        #expect(snapshot == .unavailable(.stopped))
    }

    @Test
    func localAPI_live_when_sameuserproof_present() async {
        // Live Group Containers enumeration can stall FileManager (iCloud /
        // File Provider). Keep this opt-in; stubbed LocalAPI tests cover the
        // parser and probe routing.
        guard ProcessInfo.processInfo.environment["FUTURATERM_LIVE_TAILSCALE"] == "1" else {
            return
        }
        let proofs = TailscaleStatus.discoverLocalAPIProofs(
            home: ProjectPath.currentHome,
            contentsOfDirectory: { dir in
                (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            }
        )
        guard !proofs.isEmpty else { return }
        let snapshot = await TailscaleStatus.probe(
            fileExists: { _ in false },
            pathEnv: "/usr/bin",
            run: { _, _ in
                Issue.record("CLI must not run when LocalAPI works")
                return (0, Data())
            }
        )
        guard case .ready = snapshot else {
            Issue.record("expected ready from live LocalAPI, got \(snapshot)")
            return
        }
    }

    /// A listening port that never speaks must not hang the suite. connect()
    /// succeeds off the listen backlog; recv must honor the timeout.
    @Test
    func liveFetchLocalAPI_returns_nil_when_the_peer_never_responds() throws {
        let listenFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try #require(listenFD >= 0)
        defer { close(listenFD) }
        var yes: Int32 = 1
        _ = setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        let bindRC: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bindRC == 0)
        try #require(listen(listenFD, 1) == 0)
        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got: Int32 = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &boundLen)
            }
        }
        try #require(got == 0)
        let port = Int(UInt16(bigEndian: bound.sin_port))
        try #require((1 ... 65535).contains(port))

        let started = Date()
        let body = TailscaleStatus.liveFetchLocalAPI(port: port, token: "tok", timeoutSeconds: 1)
        #expect(body == nil)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 3)
        #expect(elapsed >= 0.2)
    }

    @Test
    func runProcess_drains_stdout_larger_than_pipe_buffer() {
        let kilobytes = 128
        let result = TailscaleStatus.runProcess(
            executable: "/bin/dd",
            arguments: ["if=/dev/zero", "bs=1024", "count=\(kilobytes)"]
        )
        #expect(result != nil)
        #expect(result?.status == 0)
        #expect(result?.stdout.count == kilobytes * 1024)
    }

    /// A child that writes and exits before the next statement after `run()`
    /// still has to land in the buffer — the handler must be armed first.
    @Test
    func runProcess_captures_stdout_from_a_fast_exiting_child() {
        let result = TailscaleStatus.runProcess(
            executable: "/bin/echo",
            arguments: ["ok"]
        )
        #expect(result != nil)
        #expect(result?.status == 0)
        #expect(result?.stdout == Data("ok\n".utf8))
    }

    @Test
    func runProcess_timeout_returns_nil() {
        let start = Date()
        let result = TailscaleStatus.runProcess(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.2
        )
        #expect(result == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
