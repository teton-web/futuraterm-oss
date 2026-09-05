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
            }
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
            }
        )
        #expect(snapshot == .unavailable(.notInstalled))
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
