import AppKit
import Foundation

/// The running app's bundle identifier — `com.davidsolheim.futuraterm.debug` in debug
/// builds, `com.davidsolheim.futuraterm` in release (see `project.yml`). Used as the
/// os.Logger subsystem so the two builds log to distinct subsystems
/// (`scripts/logs.sh`). Falls back to the release ID in non-bundle contexts
/// (e.g. unit tests).
let appBundleID = Bundle.main.bundleIdentifier ?? "com.davidsolheim.futuraterm"

/// The running app's display name — "FuturaTerm Debug" in debug builds,
/// "FuturaTerm" in release (`PRODUCT_DISPLAY_NAME` in `project.yml` →
/// `CFBundleDisplayName`). Used wherever the app refers to itself by name —
/// the Application Support directory, window titles, dialogs — so the debug
/// build keeps its own identity and data, mirroring the bundle-ID split
/// above. Falls back to the release name in non-bundle contexts (e.g. unit
/// tests).
let appDisplayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "FuturaTerm"

/// Marketing version, Sparkle build, and git commit from Info.plist.
/// `scripts/build.sh` overrides these; Debug/`swift run` leave the
/// `GIT_COMMIT_PLACEHOLDER` so About/Settings can hide it.
enum AppVersion {
    static let gitCommitPlaceholder = "GIT_COMMIT_PLACEHOLDER"

    struct Info: Equatable {
        var shortVersion: String
        var buildVersion: String
        var gitCommit: String?
    }

    static func info(
        shortVersion: String?,
        buildVersion: String?,
        gitCommit: String?
    ) -> Info {
        let short = resolved(shortVersion, fallback: "0.0.0")
        let build = resolved(buildVersion, fallback: short)
        let commit = resolved(gitCommit, fallback: "")
        let looksReal = !commit.isEmpty && commit != gitCommitPlaceholder
        return Info(
            shortVersion: short,
            buildVersion: build,
            gitCommit: looksReal ? commit : nil
        )
    }

    static func info(from bundle: Bundle) -> Info {
        let dictionary = bundle.infoDictionary
        return info(
            shortVersion: dictionary?["CFBundleShortVersionString"] as? String,
            buildVersion: dictionary?["CFBundleVersion"] as? String,
            gitCommit: dictionary?["GitCommit"] as? String
        )
    }

    /// Settings / About marketing line: `0.0.0 (c5b5129)` when the commit is
    /// real, otherwise just the short version.
    static func displayString(from info: Info) -> String {
        if let commit = info.gitCommit {
            return "\(info.shortVersion) (\(commit))"
        }
        return info.shortVersion
    }

    static func displayString(from bundle: Bundle = .main) -> String {
        displayString(from: info(from: bundle))
    }

    /// Smaller About-panel build line: git commit when present, else the
    /// Sparkle `CFBundleVersion` when it differs from the marketing version.
    static func aboutBuildString(from info: Info) -> String? {
        if let commit = info.gitCommit {
            return commit
        }
        if info.buildVersion != info.shortVersion {
            return info.buildVersion
        }
        return nil
    }

    static func aboutPanelOptions(from bundle: Bundle = .main) -> [NSApplication.AboutPanelOptionKey: Any] {
        let info = info(from: bundle)
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationVersion: info.shortVersion,
        ]
        if let build = aboutBuildString(from: info) {
            options[.version] = build
        }
        return options
    }

    private static func resolved(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}
