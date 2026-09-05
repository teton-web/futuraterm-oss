import Foundation
@testable import FuturaTerm
import Testing

@MainActor
struct LocalListenerInventoryTests {
    private let uid: uid_t = 501
    private let selfPid: pid_t = 1

    private func socket(
        pid: pid_t = 9,
        command: String = "node",
        uid: uid_t = 501,
        address: String = "127.0.0.1",
        port: Int = 3000
    ) -> LocalListenerInventory.Socket {
        LocalListenerInventory.Socket(pid: pid, command: command, uid: uid, address: address, port: port)
    }

    private func fixture(_ text: String) -> Data {
        Data(text.utf8)
    }

    private func project(_ name: String, path: String, id: UUID = UUID()) -> Project {
        Project(id: id, name: name, path: path)
    }

    @Test
    func parse_loopback_ipv4() {
        let data = fixture("p9\ncnode\nu501\nn127.0.0.1:3000\n")
        let sockets = LocalListenerInventory.parseLsofF(data)
        #expect(sockets.count == 1)
        #expect(sockets[0].pid == 9)
        #expect(sockets[0].command == "node")
        #expect(sockets[0].uid == 501)
        #expect(sockets[0].address == "127.0.0.1")
        #expect(sockets[0].port == 3000)
    }

    @Test
    func parse_ipv6_brackets_and_wildcard() {
        let data = fixture("p9\ncnode\nu501\nn[::1]:3000\nn*:5173\n")
        let sockets = LocalListenerInventory.parseLsofF(data)
        #expect(sockets.map(\.address) == ["::1", "*"])
        #expect(sockets.map(\.port) == [3000, 5173])
    }

    @Test
    func parse_skips_non_numeric_port() {
        let data = fixture("p9\ncsshd\nu501\nn*:https\n")
        #expect(LocalListenerInventory.parseLsofF(data).isEmpty)
    }

    @Test
    func loopback_include_and_display_url() {
        let data = fixture("p9\ncnode\nu501\nn127.0.0.1:3000\n")
        let sockets = LocalListenerInventory.parseLsofF(data)
        let list = LocalListenerInventory.rows(
            sockets: sockets,
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in nil },
            argv: { _ in nil },
            projects: []
        )
        #expect(list.count == 1)
        #expect(list[0].id == "9:3000")
        #expect(list[0].displayURL == "http://127.0.0.1:3000")
        #expect(LocalListenerInventory.shouldInclude(sockets[0], uid: uid, selfPid: selfPid))
    }

    @Test
    func uid_mismatch_excluded() {
        let sock = socket(uid: 501)
        #expect(LocalListenerInventory.shouldInclude(sock, uid: 502, selfPid: selfPid) == false)
        let list = LocalListenerInventory.rows(
            sockets: [sock],
            uid: 502,
            selfPid: selfPid,
            cwd: { _ in nil },
            argv: { _ in nil },
            projects: []
        )
        #expect(list.isEmpty)
    }

    @Test
    func self_pid_excluded() {
        let sock = socket(pid: 42)
        #expect(LocalListenerInventory.shouldInclude(sock, uid: uid, selfPid: 42) == false)
        let list = LocalListenerInventory.rows(
            sockets: [sock],
            uid: uid,
            selfPid: 42,
            cwd: { _ in nil },
            argv: { _ in nil },
            projects: []
        )
        #expect(list.isEmpty)
    }

    @Test
    func wildcard_sshd_port_22_excluded() {
        let sock = socket(command: "sshd", address: "*", port: 22)
        #expect(LocalListenerInventory.shouldInclude(sock, uid: uid, selfPid: selfPid) == false)
    }

    @Test
    func wildcard_node_5173_included() {
        let sock = socket(command: "node", address: "*", port: 5173)
        #expect(LocalListenerInventory.shouldInclude(sock, uid: uid, selfPid: selfPid))
        let list = LocalListenerInventory.rows(
            sockets: [sock],
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in nil },
            argv: { _ in nil },
            projects: []
        )
        #expect(list.count == 1)
        #expect(list[0].id == "9:5173")
    }

    @Test
    func mdnsresponder_denylist_excluded() {
        let sock = socket(command: "mDNSResponder", address: "*", port: 5353)
        #expect(LocalListenerInventory.shouldInclude(sock, uid: uid, selfPid: selfPid) == false)
    }

    @Test
    func ipv4_ipv6_same_pid_port_deduped_prefers_loopback() {
        let sockets = [
            socket(address: "*", port: 3000),
            socket(address: "::1", port: 3000),
        ]
        let list = LocalListenerInventory.rows(
            sockets: sockets,
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in nil },
            argv: { _ in nil },
            projects: []
        )
        #expect(list.count == 1)
        #expect(list[0].address == "::1")
        #expect(list[0].id == "9:3000")
    }

    @Test
    func loopback_127_0_0_2_is_included() {
        let sock = socket(address: "127.0.0.2", port: 3001)
        #expect(LocalListenerInventory.shouldInclude(sock, uid: uid, selfPid: selfPid))
        let list = LocalListenerInventory.rows(
            sockets: [sock],
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in nil },
            argv: { _ in nil },
            projects: []
        )
        #expect(list.count == 1)
        #expect(list[0].displayURL == "http://127.0.0.1:3001")
    }

    @Test
    func unique_local_project_match() {
        let sock = socket()
        let app = project("App", path: "/tmp/app")
        let list = LocalListenerInventory.rows(
            sockets: [sock],
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in "/tmp/app" },
            argv: { _ in nil },
            projects: [app]
        )
        #expect(list[0].projectName == "App")
        #expect(list[0].projectID == app.id)
    }

    @Test
    func tmp_project_matches_private_tmp_cwd() {
        let sock = socket()
        let app = project("App", path: "/tmp/futuraterm-listener-app")
        let list = LocalListenerInventory.rows(
            sockets: [sock],
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in "/private/tmp/futuraterm-listener-app" },
            argv: { _ in nil },
            projects: [app]
        )
        #expect(list[0].projectName == "App")
        #expect(list[0].projectID == app.id)
    }

    @Test
    func symlink_project_root_matches_realpath_cwd() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("listener-symlink-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        let sock = socket()
        let app = project("App", path: link.path)
        let list = LocalListenerInventory.rows(
            sockets: [sock],
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in real.path },
            argv: { _ in nil },
            projects: [app]
        )
        #expect(list[0].projectName == "App")
        #expect(list[0].projectID == app.id)
    }

    @Test
    func nested_projects_prefer_longest_root() {
        let sock = socket()
        let parent = project("Parent", path: "/tmp/app")
        let child = project("Child", path: "/tmp/app/web")
        let list = LocalListenerInventory.rows(
            sockets: [sock],
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in "/tmp/app/web" },
            argv: { _ in nil },
            projects: [parent, child]
        )
        #expect(list[0].projectName == "Child")
        #expect(list[0].projectID == child.id)
    }

    @Test
    func ambiguous_projects_nil() {
        let sock = socket()
        let list = LocalListenerInventory.rows(
            sockets: [sock],
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in "/tmp/app" },
            argv: { _ in nil },
            projects: [
                project("A", path: "/tmp/app"),
                project("B", path: "/tmp/app"),
            ]
        )
        #expect(list[0].projectName == nil)
        #expect(list[0].projectID == nil)
    }

    @Test
    func remote_and_pinned_projects_skipped() {
        let sock = socket()
        let remote = project("Remote", path: "host:dir")
        let pinned = PinnedTabs.project
        let list = LocalListenerInventory.rows(
            sockets: [sock],
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in "/tmp/app" },
            argv: { _ in nil },
            projects: [remote, pinned]
        )
        #expect(list[0].projectName == nil)
    }

    @Test
    func argv_summary_truncates_and_skips_command_only() {
        let sock = socket()
        let long = Array(repeating: "token", count: 30)
        let withArgv = LocalListenerInventory.rows(
            sockets: [sock],
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in nil },
            argv: { _ in long },
            projects: []
        )
        #expect(withArgv[0].argvSummary?.count == 80)

        let commandOnly = LocalListenerInventory.rows(
            sockets: [sock],
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in nil },
            argv: { _ in ["node"] },
            projects: []
        )
        #expect(commandOnly[0].argvSummary == nil)
    }

    @Test
    func probe_nil_is_unavailable() async {
        let snapshot = await LocalListenerInventory.probe(
            run: { _, _ in nil },
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in nil },
            argv: { _ in nil },
            projects: []
        )
        #expect(snapshot == .unavailable)
    }

    @Test
    func probe_exit_1_empty_is_ready_empty() async {
        let snapshot = await LocalListenerInventory.probe(
            run: { _, _ in (1, Data()) },
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in nil },
            argv: { _ in nil },
            projects: []
        )
        #expect(snapshot == .ready([]))
    }

    @Test
    func liveRun_is_noop_in_tests() async {
        let result = await LocalListenerInventory.liveRun(
            executable: LocalListenerInventory.lsofExecutable,
            arguments: LocalListenerInventory.lsofArguments
        )
        #expect(result == nil)
    }

    @Test
    func probe_passes_lsof_argv() async {
        var seenExe = ""
        var seenArgs: [String] = []
        _ = await LocalListenerInventory.probe(
            run: { exe, args in
                seenExe = exe
                seenArgs = args
                return (1, Data())
            },
            uid: uid,
            selfPid: selfPid,
            cwd: { _ in nil },
            argv: { _ in nil },
            projects: []
        )
        #expect(seenExe == "/usr/sbin/lsof")
        #expect(seenArgs == ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcun"])
    }

    @Test
    func node_python_postgres_not_denied() {
        for command in ["node", "Python", "postgres", "redis-server", "docker-proxy"] {
            let sock = socket(command: command, address: "*", port: 5432)
            #expect(LocalListenerInventory.shouldInclude(sock, uid: uid, selfPid: selfPid))
        }
    }
}
