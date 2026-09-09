import Foundation
@testable import FuturaTerm
import Testing

struct ControlProtocolTests {
    // MARK: - Framing

    @Test
    func request_roundtrips_with_newline_framing() throws {
        let request = ControlRequest(command: "pane.list", args: ControlArgs(project: "demo", tab: "tab:2"))
        let encoded = try ControlProtocol.encode(request)
        #expect(encoded.last == 0x0A)
        let decoded = try ControlProtocol.decodeRequest(encoded)
        #expect(decoded.id == request.id)
        #expect(decoded.command == "pane.list")
        #expect(decoded.args == ControlArgs(project: "demo", tab: "tab:2"))
        #expect(decoded.v == ControlProtocol.version)
    }

    @Test
    func response_roundtrips_success_and_failure() throws {
        let success = ControlResponse.success(
            id: "abc",
            data: ControlData(status: ControlStatusInfo(version: "1.0", pid: 42, activeProject: "p", activeProjectID: nil))
        )
        let decodedSuccess = try ControlProtocol.decodeResponse(ControlProtocol.encode(success))
        #expect(decodedSuccess.ok)
        #expect(decodedSuccess.id == "abc")
        #expect(decodedSuccess.data?.status?.pid == 42)
        #expect(decodedSuccess.error == nil)

        let failure = ControlResponse.failure(
            id: "def",
            error: ControlError(code: .notFound, message: "nope", action: "look elsewhere")
        )
        let decodedFailure = try ControlProtocol.decodeResponse(ControlProtocol.encode(failure))
        #expect(!decodedFailure.ok)
        #expect(decodedFailure.error?.code == .notFound)
        #expect(decodedFailure.error?.action == "look elsewhere")
    }

    /// The wire format the CLI emits, hand-built: guards against accidental
    /// key renames on the app side.
    @Test
    func app_decodes_hand_built_cli_request() throws {
        let json = #"{"v":1,"id":"x1","command":"session.info","args":{"session":"futuraterm-demo-abc123"}}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\n").utf8))
        #expect(decoded.command == "session.info")
        #expect(decoded.args?.session == "futuraterm-demo-abc123")
    }

    /// Unknown args keys must be ignored (forward compatibility: a newer CLI
    /// against an older app).
    @Test
    func unknown_args_fields_are_ignored() throws {
        let json = #"{"v":1,"id":"x2","command":"status","args":{"future_flag":"yes"}}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\n").utf8))
        #expect(decoded.command == "status")
        #expect(decoded.args == ControlArgs())
    }

    @Test
    func error_codes_use_snake_case_raw_values() {
        #expect(ControlErrorCode.notFound.rawValue == "not_found")
        #expect(ControlErrorCode.unknownCommand.rawValue == "unknown_command")
        #expect(ControlErrorCode.noSurface.rawValue == "no_surface")
        #expect(ControlErrorCode.badRequest.rawValue == "bad_request")
        #expect(ControlErrorCode.internalError.rawValue == "internal")
    }

    @Test
    func decode_tolerates_trailing_whitespace_and_crlf() throws {
        let json = #"{"v":1,"id":"x3","command":"status"}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\r\n").utf8))
        #expect(decoded.command == "status")
    }

    @Test
    func pane_response_without_execution_state_remains_decodable() throws {
        let json = #"""
        {
          "v": 1,
          "id": "old",
          "ok": true,
          "data": {
            "panes": [{
              "index": 1,
              "id": "p",
              "session": "futuraterm-demo",
              "tabIndex": 1,
              "tabID": "t",
              "title": "zsh",
              "focused": true
            }]
          }
        }
        """#
        let decoded = try ControlProtocol.decodeResponse(Data((json + "\n").utf8))
        #expect(decoded.data?.panes?.first?.state == nil)
    }

    // MARK: - New verbs (#165/#166/#167)

    @Test
    func request_roundtrips_new_args_fields() throws {
        let args = ControlArgs(pane: "pane:2", scrollback: true, axis: "vertical", ratio: 0.42)
        let request = ControlRequest(command: "pane.resize-split", args: args)
        let decoded = try ControlProtocol.decodeRequest(ControlProtocol.encode(request))
        #expect(decoded.args?.scrollback == true)
        #expect(decoded.args?.axis == "vertical")
        #expect(decoded.args?.ratio == 0.42)
        #expect(decoded.args == args)
    }

    @Test
    func request_roundtrips_project_open_run_and_reuse() throws {
        let args = ControlArgs(path: "/tmp/p", run: "grok", reuse: false)
        let request = ControlRequest(command: "project.open", args: args)
        let decoded = try ControlProtocol.decodeRequest(ControlProtocol.encode(request))
        #expect(decoded.command == "project.open")
        #expect(decoded.args?.path == "/tmp/p")
        #expect(decoded.args?.run == "grok")
        #expect(decoded.args?.reuse == false)
        #expect(decoded.args == args)
    }

    @Test
    func request_roundtrips_cell_col_and_row() throws {
        let args = ControlArgs(pane: "pane:1", cellCol: 2, cellRow: 5)
        let request = ControlRequest(command: "pane.click", args: args)
        let encoded = try ControlProtocol.encode(request)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(json.contains("\"cellCol\":2"))
        #expect(json.contains("\"cellRow\":5"))
        let decoded = try ControlProtocol.decodeRequest(encoded)
        #expect(decoded.command == "pane.click")
        #expect(decoded.args?.cellCol == 2)
        #expect(decoded.args?.cellRow == 5)
        #expect(decoded.args == args)
        #expect(decoded.v == ControlProtocol.version)
    }

    @Test
    func omitted_cell_col_and_row_decode_as_nil() throws {
        let json = #"{"v":1,"id":"x5","command":"pane.click","args":{"session":"futuraterm-demo"}}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\n").utf8))
        #expect(decoded.args?.session == "futuraterm-demo")
        #expect(decoded.args?.cellCol == nil)
        #expect(decoded.args?.cellRow == nil)
    }

    @Test
    func request_roundtrips_pane_select_args() throws {
        let args = ControlArgs(
            pane: "pane:1",
            cellCol: 1,
            cellRow: 2,
            endCol: 8,
            endRow: 2,
            start: 0,
            length: 4,
            line: 3
        )
        let request = ControlRequest(command: "pane.select", args: args)
        let decoded = try ControlProtocol.decodeRequest(ControlProtocol.encode(request))
        #expect(decoded.args == args)
        #expect(decoded.args?.endCol == 8)
        #expect(decoded.args?.start == 0)
        #expect(decoded.args?.length == 4)
        #expect(decoded.args?.line == 3)
    }

    @Test
    func response_roundtrips_selection_payload() throws {
        let selection = ControlPaneSelection(
            session: "futuraterm-demo-abc123def456",
            hasSelection: true,
            text: "hi",
            start: 10,
            length: 2
        )
        let response = ControlResponse.success(id: "s1", data: ControlData(selection: selection))
        let decoded = try ControlProtocol.decodeResponse(ControlProtocol.encode(response))
        #expect(decoded.data?.selection == selection)
    }

    @Test
    func omitted_reuse_decodes_as_nil() throws {
        let json = #"{"v":1,"id":"x4","command":"project.open","args":{"path":"/tmp/p","run":"grok"}}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\n").utf8))
        #expect(decoded.args?.run == "grok")
        #expect(decoded.args?.reuse == nil)
    }

    @Test
    func response_roundtrips_inspect_payload() throws {
        let inspect = ControlPaneInspect(
            id: "pane-id", session: "futuraterm-demo-abc123def456",
            cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 17, widthPx: 640, heightPx: 408,
            scrollbackTotal: 204, scrollbackOffset: 0, scrollbackLen: 24,
            altScreen: false, contentScale: 2.0,
            foregroundPID: 4242, foregroundArgv: ["hx", "src/main.rs"],
            processExited: false, needsConfirmQuit: true
        )
        let response = ControlResponse.success(id: "i1", data: ControlData(inspect: inspect))
        let decoded = try ControlProtocol.decodeResponse(ControlProtocol.encode(response))
        #expect(decoded.data?.inspect == inspect)
    }

    @Test
    func response_roundtrips_dump_payload() throws {
        let dump = ControlPaneDump(
            id: "pane-id", session: "futuraterm-demo-abc123def456",
            scrollback: true, bytes: 5, text: "hello",
            quietTimedOut: true
        )
        let response = ControlResponse.success(id: "d1", data: ControlData(dump: dump))
        let decoded = try ControlProtocol.decodeResponse(ControlProtocol.encode(response))
        #expect(decoded.data?.dump == dump)
    }

    @Test
    func dump_payload_decodes_without_quietTimedOut() throws {
        let json = """
        {"v":1,"id":"d1","ok":true,"data":{"dump":{"id":"p","session":"s","scrollback":false,"bytes":1,"text":"x"}}}
        """
        let decoded = try ControlProtocol.decodeResponse(Data((json + "\n").utf8))
        #expect(decoded.data?.dump?.text == "x")
        #expect(decoded.data?.dump?.quietTimedOut == nil)
    }

    @Test
    func receive_timeout_covers_dump_timeout_ms() {
        #expect(ControlProtocol.receiveTimeoutSeconds(timeoutMs: nil) == 10)
        #expect(ControlProtocol.receiveTimeoutSeconds(timeoutMs: 5000) == 10)
        #expect(ControlProtocol.receiveTimeoutSeconds(timeoutMs: 10000) == 12)
        #expect(ControlProtocol.receiveTimeoutSeconds(timeoutMs: 30000) == 32)
    }

    @Test
    func request_roundtrips_dump_quiet_ms() throws {
        let args = ControlArgs(quietMs: 250, timeoutMs: 8000)
        let request = ControlRequest(command: "pane.dump", args: args)
        let decoded = try ControlProtocol.decodeRequest(ControlProtocol.encode(request))
        #expect(decoded.args?.quietMs == 250)
        #expect(decoded.args?.timeoutMs == 8000)
    }

    @Test
    func request_roundtrips_pane_choose_choice() throws {
        let args = ControlArgs(pane: "pane:1", choice: 2)
        let request = ControlRequest(command: "pane.choose", args: args)
        let decoded = try ControlProtocol.decodeRequest(ControlProtocol.encode(request))
        #expect(decoded.args == args)
        #expect(decoded.args?.choice == 2)
    }

    @Test
    func response_roundtrips_choices_payload() throws {
        let choices = [
            ControlPaneChoice(index: 1, label: "First", line: 3, column: 2, selected: true),
            ControlPaneChoice(index: 2, label: "Second", line: 4, column: 1, selected: false),
        ]
        let response = ControlResponse.success(id: "c1", data: ControlData(choices: choices))
        let decoded = try ControlProtocol.decodeResponse(ControlProtocol.encode(response))
        #expect(decoded.data?.choices == choices)
        let json = String(decoding: ControlProtocol.encode(response), as: UTF8.self)
        #expect(json.contains("\"index\":1"))
        #expect(json.contains("\"label\":\"First\""))
        #expect(json.contains("\"selected\":true"))
    }

    @Test
    func omitted_choice_decodes_as_nil() throws {
        let json = #"{"v":1,"id":"x6","command":"pane.choose","args":{"session":"futuraterm-demo"}}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\n").utf8))
        #expect(decoded.args?.choice == nil)
    }

    // MARK: - Env names (POR-354)

    @Test
    func socket_and_session_env_vars_are_futuraterm() {
        #expect(ControlProtocol.socketEnvVar == "FUTURATERM_SOCKET")
        #expect(ControlProtocol.sessionEnvVar == "FUTURATERM_SESSION")
    }

    @Test
    func socket_candidate_paths_read_futuraterm_socket_env() {
        let appSupport = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)

        let onlyNew = ControlProtocol.socketCandidatePaths(
            environment: ["FUTURATERM_SOCKET": "/tmp/new.sock"],
            appSupportDirectory: appSupport
        )
        #expect(onlyNew.first == "/tmp/new.sock")

        let override = ControlProtocol.socketCandidatePaths(
            override: "/tmp/pin.sock",
            environment: ["FUTURATERM_SOCKET": "/tmp/new.sock"],
            appSupportDirectory: appSupport
        )
        #expect(override == ["/tmp/pin.sock"])
    }

    @Test
    func session_hint_reads_futuraterm_session_env() {
        #expect(ControlProtocol.sessionHint(from: ["FUTURATERM_SESSION": "neu"]) == "neu")
        #expect(ControlProtocol.sessionHint(from: ["FUTURATERM_SESSION": ""]) == nil)
        #expect(ControlProtocol.sessionHint(from: [:]) == nil)
    }
}
