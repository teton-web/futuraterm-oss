import AppKit
import Foundation
@testable import FuturaTerm
import Testing

struct FuturaTermURLTests {
    @Test
    func host_open_with_absolute_path() throws {
        let url = try #require(URL(string: "futuraterm://open?path=/Users/me/GitHub/futuraterm"))
        #expect(FuturaTermURL.parse(url) == .open(path: "/Users/me/GitHub/futuraterm"))
    }

    @Test
    func empty_host_path_component_open() throws {
        let url = try #require(URL(string: "futuraterm:///open?path=/tmp"))
        #expect(FuturaTermURL.parse(url) == .open(path: "/tmp"))
    }

    @Test
    func percent_encoded_spaces() throws {
        let url = try #require(URL(string: "futuraterm://open?path=/tmp/my%20dir"))
        #expect(FuturaTermURL.parse(url) == .open(path: "/tmp/my dir"))
    }

    @Test
    func percent_encoded_slashes() throws {
        let url = try #require(URL(string: "futuraterm://open?path=%2FUsers%2Fme"))
        #expect(FuturaTermURL.parse(url) == .open(path: "/Users/me"))
    }

    @Test
    func tilde_path_is_accepted_as_parse() throws {
        let url = try #require(URL(string: "futuraterm://open?path=~/dev/api"))
        #expect(FuturaTermURL.parse(url) == .open(path: "~/dev/api"))
    }

    @Test
    func tilde_projects_path_is_accepted_as_parse() throws {
        let url = try #require(URL(string: "futuraterm://open?path=~/Projects/foo"))
        #expect(FuturaTermURL.parse(url) == .open(path: "~/Projects/foo"))
    }

    @Test
    func relative_path_is_nil() throws {
        let url = try #require(URL(string: "futuraterm://open?path=relative"))
        #expect(FuturaTermURL.parse(url) == nil)
    }

    @Test
    func relative_nested_path_is_nil() throws {
        let url = try #require(URL(string: "futuraterm://open?path=foo/bar"))
        #expect(FuturaTermURL.parse(url) == nil)
    }

    @Test
    func host_dir_remote_spec_is_nil() throws {
        let url = try #require(URL(string: "futuraterm://open?path=evil.example:~/"))
        #expect(FuturaTermURL.parse(url) == nil)
    }

    @Test
    func user_host_dir_remote_spec_is_nil() throws {
        let url = try #require(URL(string: "futuraterm://open?path=deploy@10.0.0.5:/srv/app"))
        #expect(FuturaTermURL.parse(url) == nil)
    }

    @Test
    func git_scp_remote_spec_is_nil() throws {
        let url = try #require(URL(string: "futuraterm://open?path=git@github.com:org/repo.git"))
        #expect(FuturaTermURL.parse(url) == nil)
    }

    @Test
    func percent_encoded_git_scp_remote_spec_is_nil() throws {
        let url = try #require(URL(string: "futuraterm://open?path=git%40github.com:org/repo.git"))
        #expect(FuturaTermURL.parse(url) == nil)
    }

    @Test
    func run_query_is_ignored() throws {
        let url = try #require(URL(string: "futuraterm://open?path=/tmp&run=rm%20-rf%20/"))
        #expect(FuturaTermURL.parse(url) == .open(path: "/tmp"))
    }

    @Test
    func missing_path_is_nil() throws {
        let url = try #require(URL(string: "futuraterm://open"))
        #expect(FuturaTermURL.parse(url) == nil)
    }

    @Test
    func empty_path_is_nil() throws {
        let url = try #require(URL(string: "futuraterm://open?path="))
        #expect(FuturaTermURL.parse(url) == nil)
    }

    @Test
    func host_is_matched_case_insensitively() throws {
        let url = try #require(URL(string: "futuraterm://OPEN?path=/tmp"))
        #expect(FuturaTermURL.parse(url) == .open(path: "/tmp"))
    }

    @Test
    func unknown_host_is_nil() throws {
        let url = try #require(URL(string: "futuraterm://other?path=/tmp"))
        #expect(FuturaTermURL.parse(url) == nil)
    }

    @Test
    func unknown_host_without_query_is_nil() throws {
        let url = try #require(URL(string: "futuraterm://foo"))
        #expect(FuturaTermURL.parse(url) == nil)
    }

    @Test
    func wrong_scheme_is_nil() throws {
        let url = try #require(URL(string: "https://open?path=/tmp"))
        #expect(FuturaTermURL.parse(url) == nil)
    }
}

@MainActor
struct FuturaTermURLRouterTests {
    private func makeHandler() -> (ControlHandler, AppState, ProjectStore) {
        let appState = AppState(
            workspaceStore: WorkspaceStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-url-tests-\(UUID().uuidString).json")),
            projectFiles: ProjectFileStore(directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-url-tests-projects-\(UUID().uuidString)", isDirectory: true))
        )
        let projectStore = ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-url-tests-store-\(UUID().uuidString).json"))
        return (ControlHandler(appState: appState, projectStore: projectStore), appState, projectStore)
    }

    private func fixtureDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-url-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func openURL(path: String, extraQuery: String = "") throws -> URL {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        return try #require(URL(string: "futuraterm://open?path=\(encoded)\(extraQuery)"))
    }

    @Test
    func queues_until_handler_attaches() async throws {
        let dir = try fixtureDir("queue")
        let url = try openURL(path: dir.path)
        let router = FuturaTermURLRouter()
        await router.openAndWait([url])
        let (handler, appState, projectStore) = makeHandler()
        #expect(projectStore.projects.isEmpty)
        await router.attachAndWait(handler)
        #expect(projectStore.projects.count == 1)
        #expect(appState.activeProjectID == projectStore.projects.first?.id)
        #expect(ProjectPath.matches(projectStore.projects[0].path, dir.path))
    }

    @Test
    func warm_open_selects_without_duplicating() async throws {
        let dir = try fixtureDir("warm")
        let (handler, appState, projectStore) = makeHandler()
        let router = FuturaTermURLRouter()
        await router.attachAndWait(handler)
        let url = try openURL(path: dir.path)
        await router.openAndWait([url])
        let firstID = try #require(projectStore.projects.first?.id)
        await router.openAndWait([url])
        #expect(projectStore.projects.count == 1)
        #expect(appState.activeProjectID == firstID)
    }

    @Test
    func run_query_does_not_spawn_a_run_tab() async throws {
        let dir = try fixtureDir("no-run")
        let (handler, appState, projectStore) = makeHandler()
        let router = FuturaTermURLRouter()
        await router.attachAndWait(handler)
        let url = try openURL(path: dir.path, extraQuery: "&run=grok")
        await router.openAndWait([url])
        #expect(projectStore.projects.count == 1)
        let projectID = try #require(projectStore.projects.first?.id)
        let panes = appState.workspaces[projectID]?.tabs.flatMap { $0.splitRoot.allPanes() } ?? []
        #expect(!panes.isEmpty)
        #expect(panes.allSatisfy { $0.command != "grok" })
        #expect(panes.allSatisfy { $0.command == nil })
    }

    @Test
    func relative_path_does_not_create_a_project() async throws {
        let (handler, _, projectStore) = makeHandler()
        let router = FuturaTermURLRouter()
        await router.attachAndWait(handler)
        let url = try #require(URL(string: "futuraterm://open?path=relative"))
        await router.openAndWait([url])
        #expect(projectStore.projects.isEmpty)
    }

    @Test
    func remote_spec_does_not_create_a_project() async throws {
        let (handler, _, projectStore) = makeHandler()
        let router = FuturaTermURLRouter()
        await router.attachAndWait(handler)
        let url = try #require(URL(string: "futuraterm://open?path=dev@host:~/dev/api"))
        await router.openAndWait([url])
        #expect(projectStore.projects.isEmpty)
    }

    @Test
    func unknown_host_does_not_create_a_project() async throws {
        let dir = try fixtureDir("unknown-host")
        let (handler, _, projectStore) = makeHandler()
        let router = FuturaTermURLRouter()
        await router.attachAndWait(handler)
        let encoded = dir.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dir.path
        let url = try #require(URL(string: "futuraterm://other?path=\(encoded)"))
        await router.openAndWait([url])
        #expect(projectStore.projects.isEmpty)
    }

    @Test
    func missing_directory_does_not_create_a_project() async throws {
        let (handler, _, projectStore) = makeHandler()
        let router = FuturaTermURLRouter()
        await router.attachAndWait(handler)
        let url = try openURL(path: "/nonexistent-\(UUID().uuidString)")
        await router.openAndWait([url])
        #expect(projectStore.projects.isEmpty)
    }

    @Test
    func app_delegate_open_queues_until_attach() async throws {
        let dir = try fixtureDir("delegate")
        let url = try openURL(path: dir.path)
        let delegate = AppDelegate()
        delegate.application(NSApp, open: [url])
        let (handler, appState, projectStore) = makeHandler()
        #expect(projectStore.projects.isEmpty)
        await delegate.urlRouter.attachAndWait(handler)
        #expect(projectStore.projects.count == 1)
        #expect(appState.activeProjectID == projectStore.projects.first?.id)
    }
}
