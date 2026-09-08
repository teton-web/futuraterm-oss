import Foundation
@testable import FuturaTerm
import Testing

struct GrokSessionLookupTests {
    @Test
    func encode_cwd_percent_encodes_slashes() {
        #expect(
            GrokSessionLookup.encodeCwd("/Users/davidsolheim/GitHub/futuraterm")
                == "%2FUsers%2Fdavidsolheim%2FGitHub%2Ffuturaterm"
        )
        #expect(GrokSessionLookup.encodeCwd("/tmp/dir/") == "%2Ftmp%2Fdir")
        #expect(GrokSessionLookup.normalizedCwd("/") == "/")
    }

    @Test
    func location_reads_uuid_from_open_session_files() throws {
        let home = "/Users/nobody/.grok"
        let id = "01a06730-0b9b-7ab2-a19a-7a635bdeaf71"
        let events = "\(home)/sessions/%2FUsers%2Fproj/\(id)/events.jsonl"
        let location = try #require(
            GrokSessionLookup.location(
                inOpenPaths: ["/usr/lib/libfoo.dylib", events],
                grokHome: home
            )
        )
        #expect(location.sessionID == id)
        #expect(location.directory.lastPathComponent == id)
        #expect(
            GrokSessionLookup.location(
                inOpenPaths: ["/tmp/unrelated.txt"],
                grokHome: home
            ) == nil
        )
    }

    @Test
    func parse_summary_prefers_created_at_and_generated_title() throws {
        let id = "01a06730-0b9b-7ab2-a19a-7a635bdeaf71"
        let json = """
        {
          "created_at": "2026-09-01T12:13:17.110879Z",
          "updated_at": "2026-09-03T09:40:00Z",
          "generated_title": "Start date chrome",
          "info": { "id": "\(id)", "cwd": "/tmp/proj" }
        }
        """
        let chrome = try #require(
            GrokSessionLookup.parseSummary(Data(json.utf8), sessionID: id)
        )
        #expect(chrome.sessionID == id)
        #expect(chrome.title == "Start date chrome")
        #expect(chrome.createdAt.timeIntervalSince1970 == GrokRFC3339.parse("2026-09-01T12:13:17.110879Z")?.timeIntervalSince1970)
        #expect(chrome.updatedAt?.timeIntervalSince1970 == GrokRFC3339.parse("2026-09-03T09:40:00Z")?.timeIntervalSince1970)
    }

    @Test
    func parse_summary_falls_back_to_uuidv7_without_created_at() throws {
        let id = "018a4e3c-0000-7000-8000-000000000000"
        let chrome = try #require(
            GrokSessionLookup.parseSummary(Data(#"{}"#.utf8), sessionID: id)
        )
        #expect(chrome.createdAt.timeIntervalSince1970 == TimeInterval(0x018A_4E3C_0000) / 1000)
        #expect(chrome.updatedAt == nil)
    }

    @Test
    func unique_session_id_matches_uuidv7_near_process_start() throws {
        let grokHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-lookup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: grokHome) }
        let cwd = "/tmp/unique-session-cwd"
        let matchID = "018a4e3c-0000-7000-8000-000000000000"
        let otherID = "018a4e3c-ffff-7000-8000-000000000000"
        let dir = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(GrokSessionLookup.encodeCwd(cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(matchID), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(otherID), withIntermediateDirectories: true)

        let start = try #require(GrokSessionAge.createdAt(fromSessionID: matchID))
        #expect(
            GrokSessionLookup.uniqueSessionID(
                cwd: cwd,
                matchingStart: start,
                grokHome: grokHome.path
            ) == matchID
        )
        #expect(
            GrokSessionLookup.uniqueSessionID(
                cwd: cwd,
                matchingStart: start.addingTimeInterval(60),
                grokHome: grokHome.path
            ) == nil
        )
    }

    @Test
    func load_chrome_reads_summary_json_from_disk() throws {
        let grokHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-lookup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: grokHome) }
        let cwd = "/tmp/load-chrome-cwd"
        let id = "01a06730-0b9b-7ab2-a19a-7a635bdeaf71"
        let dir = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(GrokSessionLookup.encodeCwd(cwd), isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"created_at":"2026-08-01T12:00:00Z","updated_at":"2026-09-03T12:00:00Z","generated_title":"Old chat"}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("summary.json"))

        let chrome = try #require(
            GrokSessionLookup.loadChrome(sessionID: id, cwd: cwd, grokHome: grokHome.path)
        )
        #expect(chrome.title == "Old chat")
        #expect(chrome.createdAt.timeIntervalSince1970 == GrokRFC3339.parse("2026-08-01T12:00:00Z")?.timeIntervalSince1970)
    }
}
