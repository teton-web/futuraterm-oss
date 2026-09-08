import Foundation
@testable import FuturaTerm
import Testing

struct SessionInventoryTests {
    private let paneID = UUID()
    private let tabID = UUID()
    private let kectilID = UUID()
    private let otherID = UUID()

    private func project(_ name: String, path: String, id: UUID) -> Project {
        Project(id: id, name: name, path: path)
    }

    private func claim(projectID: UUID, projectName: String) -> SessionInventory.Claim {
        SessionInventory.Claim(paneID: paneID, tabID: tabID, projectID: projectID, projectName: projectName)
    }

    private func entry(_ name: String, clients: Int? = 0) -> ZmxSessionListParser.Entry {
        ZmxSessionListParser.Entry(name: name, clients: clients)
    }

    private func rows(
        entries: [ZmxSessionListParser.Entry],
        leaders: [String: pid_t] = [:],
        claims: [String: SessionInventory.Claim] = [:],
        projects: [Project] = [],
        inspect: (String) -> (comm: String?, cwd: String?) = { _ in (nil, nil) }
    ) -> [SessionInventory.Row] {
        SessionInventory.rows(
            entries: entries,
            leaders: leaders,
            claims: claims,
            projects: projects,
            inspect: inspect
        )
    }

    @Test
    func one_row_per_entry_including_foreign() {
        let ft = "futuraterm-kectil-aaaaaaaaaaaa"
        let foreign = "tmux-main"
        let result = rows(entries: [entry(ft), entry(foreign)])
        #expect(result.map(\.name) == [ft, foreign])
        #expect(result[0].kind == .futuraterm)
        #expect(result[1].kind == .foreign)
        #expect(result[1].attachment == .unattached)
        #expect(result[1].claim == nil)
        #expect(result[1].suggestedProjectName == nil)
    }

    @Test
    func claimed_session_is_attached_without_suggestion() {
        let name = "futuraterm-kectil-aaaaaaaaaaaa"
        let c = claim(projectID: kectilID, projectName: "Kectil")
        let result = rows(
            entries: [entry(name, clients: 1)],
            claims: [name: c],
            projects: [project("Kectil", path: "/tmp/k", id: kectilID)]
        )
        #expect(result.count == 1)
        #expect(result[0].attachment == .attached)
        #expect(result[0].claim == c)
        #expect(result[0].suggestedProjectName == nil)
    }

    @Test
    func unique_slug_suggests_project_name() {
        let name = "futuraterm-kectil-aaaaaaaaaaaa"
        let result = rows(
            entries: [entry(name)],
            projects: [
                project("Kectil", path: "/tmp/k", id: kectilID),
                project("Other", path: "/tmp/o", id: otherID),
            ]
        )
        #expect(result[0].attachment == .unattached)
        #expect(result[0].suggestedProjectName == "Kectil")
        #expect(result[0].claim == nil)
    }

    @Test
    func zero_or_two_slug_hits_suggest_nil() {
        let name = "futuraterm-kectil-aaaaaaaaaaaa"
        let none = rows(
            entries: [entry(name)],
            projects: [project("Other", path: "/tmp/o", id: otherID)]
        )
        #expect(none[0].suggestedProjectName == nil)

        let two = rows(
            entries: [entry(name)],
            projects: [
                project("Kectil", path: "/tmp/a", id: kectilID),
                project("kectil!", path: "/tmp/b", id: otherID),
            ]
        )
        #expect(two[0].suggestedProjectName == nil)
    }

    @Test
    func pinned_and_remote_projects_are_ignored_for_suggestions() {
        let name = "futuraterm-kectil-aaaaaaaaaaaa"
        let pinned = PinnedTabs.project
        let remote = project("Kectil", path: "host:dir", id: kectilID)
        let result = rows(
            entries: [entry(name)],
            projects: [pinned, remote]
        )
        #expect(result[0].suggestedProjectName == nil)
    }

    @Test
    func generic_and_quick_slugs_do_not_suggest() {
        let generic = "futuraterm-project-aaaaaaaaaaaa"
        let quick = "futuraterm-quick-aaaaaaaaaaaa"
        #expect(ZmxSessionName.slug(fromName: generic) == ZmxSessionName.genericSlug)
        #expect(ZmxSessionName.slug(fromName: quick) == ZmxSessionName.quickTerminalSlug)
        let projects = [
            project("project", path: "/tmp/p", id: kectilID),
            project("quick", path: "/tmp/q", id: otherID),
        ]
        let result = rows(entries: [entry(generic), entry(quick)], projects: projects)
        #expect(result.allSatisfy { $0.suggestedProjectName == nil })
    }

    @Test
    func clients_nil_is_preserved() {
        let name = "futuraterm-kectil-aaaaaaaaaaaa"
        let result = rows(entries: [entry(name, clients: nil)])
        #expect(result[0].clients == nil)
    }

    @Test
    func leader_pid_from_map_else_nil() {
        let a = "futuraterm-alpha-aaaaaaaaaaaa"
        let b = "futuraterm-beta-bbbbbbbbbbbb"
        let result = rows(
            entries: [entry(a), entry(b)],
            leaders: [a: 4242]
        )
        let byName = Dictionary(uniqueKeysWithValues: result.map { ($0.name, $0) })
        #expect(byName[a]?.leaderPID == 4242)
        #expect(byName[b]?.leaderPID == nil)
    }

    @Test
    func inspect_comm_becomes_foreground_name() {
        let name = "futuraterm-kectil-aaaaaaaaaaaa"
        let result = rows(entries: [entry(name)]) { _ in (comm: "nvim", cwd: "/tmp") }
        #expect(result[0].foregroundName == "nvim")
    }

    @Test
    func sort_attached_then_unattached_then_foreign() {
        let attachedB = "futuraterm-zeta-bbbbbbbbbbbb"
        let attachedA = "futuraterm-alpha-aaaaaaaaaaaa"
        let unattachedZ = "futuraterm-zzz-cccccccccccccccc"
        let unattachedA = "futuraterm-aaa-dddddddddddd"
        let foreignZ = "zsh-session"
        let foreignA = "Other-tmux"
        let claimA = claim(projectID: kectilID, projectName: "Beta")
        let claimB = claim(projectID: otherID, projectName: "Alpha")
        let result = rows(
            entries: [
                entry(foreignZ),
                entry(unattachedZ),
                entry(attachedA),
                entry(foreignA),
                entry(unattachedA),
                entry(attachedB),
            ],
            claims: [
                attachedA: claimA,
                attachedB: claimB,
            ]
        )
        #expect(result.map(\.name) == [
            attachedB,
            attachedA,
            unattachedA,
            unattachedZ,
            foreignA,
            foreignZ,
        ])
    }
}
