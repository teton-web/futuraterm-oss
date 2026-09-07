import Foundation
@testable import FuturaTerm
import Testing

struct GrokSessionAdoptionTests {
    private let kectilID = UUID()
    private let otherID = UUID()
    private let kectilName = "futuraterm-kectil-aaaaaaaaaaaa"

    private func project(_ name: String, path: String, id: UUID) -> Project {
        Project(id: id, name: name, path: path)
    }

    private func candidate(
        _ name: String,
        cwd: String? = nil
    ) -> GrokSessionAdoption.Candidate {
        GrokSessionAdoption.Candidate(
            sessionName: name,
            slug: ZmxSessionName.slug(fromName: name) ?? "",
            cwd: cwd
        )
    }

    private func grokInspect(cwd: String? = "/Users/x/code/app") -> (String) -> (comm: String?, cwd: String?) {
        { _ in (comm: "grok", cwd: cwd) }
    }

    // MARK: - Gather

    @Test
    func candidates_keep_unclaimed_grok_sessions() {
        let entries = [
            ZmxSessionListParser.Entry(name: kectilName, clients: 0),
        ]
        let result = GrokSessionAdoption.candidates(
            from: entries,
            claimed: [],
            inspect: grokInspect()
        )
        #expect(result == [candidate(kectilName, cwd: "/Users/x/code/app")])
    }

    @Test
    func candidates_include_unclaimed_sessions_with_clients() {
        let entries = [
            ZmxSessionListParser.Entry(name: kectilName, clients: 1),
        ]
        let result = GrokSessionAdoption.candidates(
            from: entries,
            claimed: [],
            inspect: grokInspect()
        )
        #expect(result.map(\.sessionName) == [kectilName])
    }

    @Test
    func candidates_drop_claimed_unknown_count_and_non_grok() {
        let grok = kectilName
        let claimed = "futuraterm-claimed-bbbbbbbbbbbb"
        let unknown = "futuraterm-unknown-cccccccccccc"
        let idle = "futuraterm-idle-dddddddddddd"
        let entries = [
            ZmxSessionListParser.Entry(name: grok, clients: 0),
            ZmxSessionListParser.Entry(name: claimed, clients: 0),
            ZmxSessionListParser.Entry(name: unknown, clients: nil),
            ZmxSessionListParser.Entry(name: idle, clients: 0),
        ]
        let result = GrokSessionAdoption.candidates(from: entries, claimed: [claimed]) { name in
            if name == idle { return (comm: "zsh", cwd: "/tmp") }
            if name == grok { return (comm: "grok", cwd: "/Users/x/code/app") }
            return (comm: "grok", cwd: "/tmp")
        }
        #expect(result.map(\.sessionName) == [grok])
    }

    @Test
    func candidates_reject_grokify_substring() {
        let entries = [
            ZmxSessionListParser.Entry(name: kectilName, clients: 0),
        ]
        let result = GrokSessionAdoption.candidates(from: entries, claimed: []) { _ in
            (comm: "grokify", cwd: "/Users/x/code/app")
        }
        #expect(result.isEmpty)
    }

    // MARK: - Assign: slug

    @Test
    func unique_slug_assigns_that_project() {
        let projects = [
            project("Kectil", path: "/Users/x/code/kectil", id: kectilID),
            project("Other", path: "/Users/x/code/other", id: otherID),
        ]
        let assignments = GrokSessionAdoption.assign(
            [candidate(kectilName, cwd: "/somewhere/else")],
            projects: projects
        )
        #expect(assignments == [.init(sessionName: kectilName, projectID: kectilID)])
    }

    @Test
    func two_projects_same_slug_skips_without_unique_cwd() {
        let projects = [
            project("Kectil", path: "/tmp/a", id: kectilID),
            project("kectil!", path: "/tmp/b", id: otherID),
        ]
        let assignments = GrokSessionAdoption.assign(
            [candidate(kectilName)],
            projects: projects
        )
        #expect(assignments.isEmpty)
    }

    @Test
    func two_projects_same_slug_unique_cwd_wins() {
        let projects = [
            project("Kectil", path: "/tmp/a", id: kectilID),
            project("kectil!", path: "/Users/x/code/app", id: otherID),
        ]
        let assignments = GrokSessionAdoption.assign(
            [candidate(kectilName, cwd: "/Users/x/code/app")],
            projects: projects
        )
        #expect(assignments == [.init(sessionName: kectilName, projectID: otherID)])
    }

    @Test
    func generic_project_slug_never_steals_via_name() {
        let session = "futuraterm-project-aaaaaaaaaaaa"
        let japanese = project("日本語プロジェクト", path: "/tmp/jp", id: kectilID)
        #expect(ZmxSessionName.slug(japanese.name) == ZmxSessionName.genericSlug)
        let assignments = GrokSessionAdoption.assign(
            [candidate(session)],
            projects: [japanese]
        )
        #expect(assignments.isEmpty)
    }

    @Test
    func generic_project_slug_uses_cwd_only() {
        let session = "futuraterm-project-aaaaaaaaaaaa"
        let japanese = project("日本語プロジェクト", path: "/tmp/jp", id: kectilID)
        let app = project("App", path: "/Users/x/code/app", id: otherID)
        let assignments = GrokSessionAdoption.assign(
            [candidate(session, cwd: "/Users/x/code/app")],
            projects: [japanese, app]
        )
        #expect(assignments == [.init(sessionName: session, projectID: otherID)])
    }

    @Test
    func two_generic_slug_projects_without_unique_cwd_skip() {
        let session = "futuraterm-project-aaaaaaaaaaaa"
        let projects = [
            project("日本語", path: "/tmp/a", id: kectilID),
            project("!!!", path: "/tmp/b", id: otherID),
        ]
        #expect(projects.allSatisfy { ZmxSessionName.slug($0.name) == ZmxSessionName.genericSlug })
        let assignments = GrokSessionAdoption.assign(
            [candidate(session, cwd: "/tmp/unrelated")],
            projects: projects
        )
        #expect(assignments.isEmpty)
    }

    // MARK: - Assign: cwd

    @Test
    func unique_cwd_matches_when_slug_misses() {
        let projects = [
            project("Renamed", path: "/Users/x/code/app", id: kectilID),
            project("Other", path: "/tmp/other", id: otherID),
        ]
        let assignments = GrokSessionAdoption.assign(
            [candidate(kectilName, cwd: "/Users/x/code/app")],
            projects: projects
        )
        #expect(assignments == [.init(sessionName: kectilName, projectID: kectilID)])
    }

    @Test
    func two_path_matches_skip() {
        let projects = [
            project("A", path: "/Users/x/code/app", id: kectilID),
            project("B", path: "/Users/x/code/app/.", id: otherID),
        ]
        let assignments = GrokSessionAdoption.assign(
            [candidate(kectilName, cwd: "/Users/x/code/app")],
            projects: projects
        )
        #expect(assignments.isEmpty)
    }

    @Test
    func remote_project_never_matches_local_cwd() {
        let projects = [
            project("Remote", path: "host:dir", id: kectilID),
            project("Local", path: "/Users/x/code/app", id: otherID),
        ]
        let remoteOnly = GrokSessionAdoption.assign(
            [candidate(kectilName, cwd: "/Users/x/code/app")],
            projects: [projects[0]]
        )
        #expect(remoteOnly.isEmpty)

        let withLocal = GrokSessionAdoption.assign(
            [candidate("futuraterm-miss-aaaaaaaaaaaa", cwd: "/Users/x/code/app")],
            projects: projects
        )
        #expect(withLocal == [.init(sessionName: "futuraterm-miss-aaaaaaaaaaaa", projectID: otherID)])
    }

    @Test
    func pinned_sentinel_is_never_a_target() {
        let pinned = PinnedTabs.project
        let assignments = GrokSessionAdoption.assign(
            [candidate("futuraterm-pinned-aaaaaaaaaaaa", cwd: PinnedTabs.fallbackRoot)],
            projects: [pinned]
        )
        #expect(assignments.isEmpty)
    }

    @Test
    func quick_terminal_slug_is_skipped() {
        let session = "futuraterm-quick-aaaaaaaaaaaa"
        #expect(ZmxSessionName.slug(fromName: session) == ZmxSessionName.quickTerminalSlug)
        let projects = [
            project("quick", path: "/Users/x/code/app", id: kectilID),
        ]
        let assignments = GrokSessionAdoption.assign(
            [candidate(session, cwd: "/Users/x/code/app")],
            projects: projects
        )
        #expect(assignments.isEmpty)
    }

    @Test
    func empty_slug_is_skipped() {
        let assignments = GrokSessionAdoption.assign(
            [GrokSessionAdoption.Candidate(sessionName: "futuraterm--aaaaaaaaaaaa", slug: "", cwd: "/tmp")],
            projects: [project("tmp", path: "/tmp", id: kectilID)]
        )
        #expect(assignments.isEmpty)
    }
}
