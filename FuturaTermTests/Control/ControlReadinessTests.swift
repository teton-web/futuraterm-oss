import Foundation
@testable import FuturaTerm
import Testing

struct ControlReadinessTests {
    // MARK: - Auto-launch eligibility

    @Test
    func should_auto_launch_when_unpinned_and_launch_allowed() {
        #expect(ControlReadiness.shouldAutoLaunch(socketOverride: nil, noLaunch: false))
    }

    @Test
    func socket_override_never_auto_launches() {
        #expect(!ControlReadiness.shouldAutoLaunch(socketOverride: "/tmp/does-not-exist.sock", noLaunch: false))
        #expect(!ControlReadiness.shouldAutoLaunch(socketOverride: "", noLaunch: false))
    }

    @Test
    func no_launch_skips_auto_launch() {
        #expect(!ControlReadiness.shouldAutoLaunch(socketOverride: nil, noLaunch: true))
    }

    @Test
    func no_launch_and_socket_override_both_skip() {
        #expect(!ControlReadiness.shouldAutoLaunch(socketOverride: "/tmp/x.sock", noLaunch: true))
    }

    // MARK: - Retry classification

    @Test
    func connection_failure_is_retryable() {
        #expect(ControlReadiness.isRetryable(connectionFailure: true, response: nil))
    }

    @Test
    func starting_response_is_retryable() {
        let response = ControlResponse.failure(
            id: "t",
            error: ControlError(code: .starting, message: "FuturaTerm is still starting up", action: "retry in a moment")
        )
        #expect(ControlReadiness.isRetryable(connectionFailure: false, response: response))
    }

    @Test
    func busy_not_found_and_bad_request_are_not_retryable() {
        for code in [ControlErrorCode.busy, .notFound, .badRequest] {
            let response = ControlResponse.failure(
                id: "t",
                error: ControlError(code: code, message: "nope")
            )
            #expect(!ControlReadiness.isRetryable(connectionFailure: false, response: response))
        }
    }

    @Test
    func other_app_errors_are_not_retryable() {
        for code in [
            ControlErrorCode.unknownCommand,
            .noSurface,
            .ambiguous,
            .internalError,
        ] {
            let response = ControlResponse.failure(
                id: "t",
                error: ControlError(code: code, message: "nope")
            )
            #expect(!ControlReadiness.isRetryable(connectionFailure: false, response: response))
        }
    }

    @Test
    func ok_response_is_not_retryable() {
        let response = ControlResponse.success(id: "t")
        #expect(!ControlReadiness.isRetryable(connectionFailure: false, response: response))
    }

    @Test
    func nil_response_without_connection_failure_is_not_retryable() {
        #expect(!ControlReadiness.isRetryable(connectionFailure: false, response: nil))
    }

    // MARK: - Nested companion URL

    @Test
    func nested_bin_path_resolves_to_enclosing_app() {
        let cli = URL(fileURLWithPath: "/Applications/FuturaTerm.app/Contents/Resources/bin/futuraterm")
        let app = ControlReadiness.companionAppURL(cliExecutable: cli)
        #expect(app?.path == "/Applications/FuturaTerm.app")
    }

    @Test
    func nested_debug_app_resolves_to_that_app_not_release() {
        let cli = URL(fileURLWithPath: "/DerivedData/FuturaTermDebug.app/Contents/Resources/bin/futuraterm")
        let app = ControlReadiness.companionAppURL(cliExecutable: cli)
        #expect(app?.path == "/DerivedData/FuturaTermDebug.app")
    }

    @Test
    func path_installed_cli_is_not_nested() {
        let cli = URL(fileURLWithPath: "/opt/homebrew/bin/futuraterm")
        #expect(ControlReadiness.companionAppURL(cliExecutable: cli) == nil)
    }

    @Test
    func app_macos_binary_is_not_the_nested_cli_layout() {
        let exe = URL(fileURLWithPath: "/Applications/FuturaTerm.app/Contents/MacOS/FuturaTerm")
        #expect(ControlReadiness.companionAppURL(cliExecutable: exe) == nil)
    }

    // MARK: - open(1) argv

    @Test
    func open_arguments_never_include_n() {
        let app = URL(fileURLWithPath: "/Applications/FuturaTerm.app")
        let byPath = ControlReadiness.openArguments(appURL: app)
        let byID = ControlReadiness.openArguments(bundleID: ControlReadiness.releaseBundleID)
        #expect(!byPath.contains("-n"))
        #expect(!byID.contains("-n"))
        #expect(byPath == ["/Applications/FuturaTerm.app"])
        #expect(byID == ["-b", "com.davidsolheim.futuraterm"])
    }

    @Test
    func launch_bundle_ids_are_release_then_debug_not_cli() {
        #expect(ControlReadiness.launchBundleIDs == [
            "com.davidsolheim.futuraterm",
            "com.davidsolheim.futuraterm.debug",
        ])
        #expect(!ControlReadiness.launchBundleIDs.contains("com.davidsolheim.futuraterm.cli"))
    }

    @Test
    func wait_budget_matches_the_issue_contract() {
        #expect(ControlReadiness.timeout == 20)
        #expect(ControlReadiness.pollInterval == 0.2)
    }
}
