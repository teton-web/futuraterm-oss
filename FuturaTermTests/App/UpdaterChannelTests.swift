import Foundation
@testable import FuturaTerm
import Sparkle
import Testing

/// The beta update channel is a **wire contract** spanning three files that
/// cannot reference each other: the Swift channel name, the
/// `<sparkle:channel>` literal written by `scripts/publish-appcast.sh`, and the
/// preference key that gates it. A rename on one side silently strands beta
/// testers — Sparkle just filters out an unrecognized channel and reports "up
/// to date" forever, with no error anywhere. These tests pin the literals.
///
/// `Updater` itself isn't instantiated here: constructing it starts Sparkle's
/// machinery (and in a hosted test bundle would fire a real update check), so
/// the tests cover the pure contract rather than the framework bridge.
@MainActor
struct UpdaterChannelTests {
    @Test
    func updater_starts_only_for_distributed_release_builds() {
        let realKey = "real-release-public-key"

        #expect(UpdaterAvailability.shouldStart(
            isDebug: false, isBenchmark: false, publicKey: realKey
        ))
        #expect(!UpdaterAvailability.shouldStart(
            isDebug: true, isBenchmark: false, publicKey: realKey
        ))
        #expect(!UpdaterAvailability.shouldStart(
            isDebug: false, isBenchmark: true, publicKey: realKey
        ))
        #expect(!UpdaterAvailability.shouldStart(
            isDebug: false,
            isBenchmark: false,
            publicKey: UpdaterAvailability.placeholderPublicKey
        ))
        #expect(!UpdaterAvailability.shouldStart(
            isDebug: false, isBenchmark: false, publicKey: nil
        ))
    }

    @Test
    func placeholder_public_key_matches_the_build_and_release_contracts() throws {
        let placeholder = UpdaterAvailability.placeholderPublicKey
        let root = repoRoot()
        let project = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let buildScript = try String(
            contentsOf: root.appendingPathComponent("scripts/build.sh"),
            encoding: .utf8
        )
        let releaseWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )

        #expect(project.contains("SPARKLE_ED_PUBLIC_KEY: \(placeholder)"))
        #expect(buildScript.contains(
            #"SPARKLE_ED_PUBLIC_KEY="${SPARKLE_ED_PUBLIC_KEY:-\#(placeholder)}""#
        ))
        // Release contract is appcast no-op without the private key, not refuse-to-build.
        #expect(releaseWorkflow.contains(
            #"if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then"#
        ))
        #expect(releaseWorkflow.contains(
            "SPARKLE_ED_PRIVATE_KEY unset; skipping appcast (auto-update stays disabled)"
        ))
    }

    /// Sparkle will not check without `SUFeedURL`. The URL is a wire contract
    /// with `publish-appcast.sh`'s futuraterm.com feed — a rename on one
    /// side 404s every updater.
    @Test
    func info_plist_declares_the_public_appcast_url() throws {
        let url = repoRoot().appendingPathComponent("FuturaTerm/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        #expect(plist["SUFeedURL"] as? String == UpdaterAvailability.appcastURL)
        #expect(UpdaterAvailability.appcastURL == "https://futuraterm.com/appcast.xml")
    }

    @Test
    func appcast_publisher_runs_from_the_private_repo_and_writes_public_urls() throws {
        let script = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/publish-appcast.sh"),
            encoding: .utf8
        )
        #expect(script.contains("teton-web/futuraterm"))
        #expect(script.contains("davidsolheim/futuraterm"))
        #expect(script.contains("https://futuraterm.com/appcast.xml"))
        #expect(script.contains("FUTURATERM_RELEASE_UPLOAD_TOKEN"))
        #expect(script.contains("Cache-Control: no-cache"))
        #expect(script.contains(#"${APPCAST_URL}?t=$(date +%s)"#))
        #expect(script.contains("https://github.com/davidsolheim/futuraterm/releases/download"))
        #expect(!script.contains("APPCAST_DEPLOY_KEY"))
        #expect(!script.contains("git clone"))
        #expect(!script.contains("github.com/${GITHUB_REPOSITORY}.git"))
    }

    @Test
    func release_workflow_publishes_the_appcast_and_public_dmg() throws {
        let yml = try String(
            contentsOf: repoRoot().appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        #expect(yml.contains("APPCAST_DEPLOY_KEY"))
        #expect(yml.contains("--repo davidsolheim/futuraterm"))
        #expect(yml.contains("ENCLOSURE_URL"))
        #expect(yml.contains("steps.website.outputs.blob_url"))
        let website = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/publish-website-release.sh"),
            encoding: .utf8
        )
        #expect(website.contains("blob_url"))
        #expect(website.contains("GITHUB_OUTPUT"))
    }

    @Test
    func settings_explains_why_local_builds_cannot_check_for_updates() throws {
        let settings = try String(
            contentsOf: repoRoot().appendingPathComponent("FuturaTerm/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(settings.contains("UpdaterAvailability.localBuildUpdatesCaption"))
        #expect(settings.contains("UpdaterAvailability.appStoreUpdatesCaption"))
        #expect(settings.contains("UpdaterAvailability.shouldStart"))
        let updater = try String(
            contentsOf: repoRoot().appendingPathComponent("FuturaTerm/App/Updater.swift"),
            encoding: .utf8
        )
        #expect(updater.contains(
            "Checking for updates is available in released builds of FuturaTerm, not this local build."
        ))
    }

    @Test
    func beta_channel_name_matches_the_appcast_literal() throws {
        // Must equal the value in publish-appcast.sh's CHANNEL_LINE. Read the
        // script rather than restating "beta", so an edit to either side fails.
        let script = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/publish-appcast.sh"),
            encoding: .utf8
        )
        #expect(script.contains("<sparkle:channel>\(betaUpdateChannel)</sparkle:channel>"))
    }

    /// Sparkle restricts channel names to letters, numbers, dashes,
    /// underscores, and periods. An invalid name is silently ignored.
    @Test
    func beta_channel_name_is_a_valid_sparkle_channel() {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_."))
        #expect(!betaUpdateChannel.isEmpty)
        #expect(betaUpdateChannel.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    /// Defaults to stable: a fresh install must never see a beta. This is the
    /// single most important behavior here — a wrong default would push every
    /// user onto prereleases at the next background check.
    @Test
    func update_channel_defaults_to_stable() throws {
        let defaults = try #require(UserDefaults(suiteName: "futuraterm.updater-channel-tests.\(UUID().uuidString)"))
        #expect(defaults.string(forKey: Preferences.Keys.updateChannel) == nil)
        // Mirrors Preferences.init's read for an unset key.
        let value = defaults.string(forKey: Preferences.Keys.updateChannel)
            .flatMap(UpdateChannel.init(rawValue:)) ?? .stable
        #expect(value == .stable)
    }

    /// An unrecognized persisted value (hand-edited defaults, or a case removed
    /// in a later version) must fall back to stable rather than stranding the
    /// user on a channel that no longer exists.
    @Test
    func unknown_persisted_channel_falls_back_to_stable() {
        let value = UpdateChannel(rawValue: "nightly") ?? .stable
        #expect(value == .stable)
    }

    @Test
    func selecting_a_channel_round_trips() {
        let prior = Preferences.shared.updateChannel
        defer { Preferences.shared.updateChannel = prior }

        Preferences.shared.updateChannel = .beta
        #expect(Preferences.shared.updateChannel == .beta)
        Preferences.shared.updateChannel = .stable
        #expect(Preferences.shared.updateChannel == .stable)
    }

    /// The picker persists `rawValue`, and `beta`'s raw value doubles as the
    /// Sparkle channel name — so a case rename would silently change both the
    /// stored preference and the wire value.
    @Test
    func channel_raw_values_are_the_persisted_and_wire_contract() {
        #expect(UpdateChannel.stable.rawValue == "stable")
        #expect(UpdateChannel.beta.rawValue == "beta")
        #expect(betaUpdateChannel == UpdateChannel.beta.rawValue)
        // Exactly two channels ship; adding one needs an appcast change too.
        #expect(UpdateChannel.allCases.count == 2)
    }

    /// Stable items must carry NO channel element — an item tagged with any
    /// channel is invisible to default updaters, so accidentally channel-tagging
    /// a stable release would silently cut off every non-beta user.
    @Test
    func publish_script_tags_only_prereleases() throws {
        let script = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/publish-appcast.sh"),
            encoding: .utf8
        )
        // The channel line is assigned only inside the PRERELEASE branch.
        let guarded = script.contains(#"if [[ "$PRERELEASE" == "true" ]]; then"#)
        #expect(guarded)
        // And the item template interpolates it rather than hardcoding it.
        #expect(script.contains("${CHANNEL_LINE}"))
    }

    // MARK: - Version ordering

    /// `sparkle_comparison_version` (scripts/_lib.sh) maps a marketing version
    /// to the 4-component string Sparkle actually ORDERS by. The mapping is
    /// exercised through the real shell helper — a Swift reimplementation here
    /// would pass while the shipped script drifted.
    ///
    /// Why the mapping exists at all: `SUStandardVersionComparator` treats a
    /// `-beta.N` suffix as insignificant, ranking `0.9.0-beta.1 == 0.9.0`. Left
    /// raw, beta→beta and beta→stable updates would silently never appear.
    @Test(arguments: [
        ("1.8.0", "1.8.0.9999"),
        ("0.9.0-beta.1", "0.9.0.1"),
        ("0.9.0-beta.10", "0.9.0.10"),
        ("0.0.0", "0.0.0.9999"),
    ])
    func comparison_version_mapping(input: String, expected: String) throws {
        #expect(try runComparisonHelper(input) == expected)
    }

    /// The ordering the whole scheme exists to produce, asserted through
    /// Sparkle's own comparator rather than by eyeballing the strings.
    @Test
    func betas_sort_below_their_stable_and_among_themselves() throws {
        let cmp = SUStandardVersionComparator()
        func version(_ v: String) throws -> String {
            try runComparisonHelper(v)
        }

        // beta 1 < beta 2 < beta 10 < stable 0.9.0 < stable 1.0.0
        let ordered = try [
            version("0.9.0-beta.1"),
            version("0.9.0-beta.2"),
            version("0.9.0-beta.10"),
            version("0.9.0"),
            version("1.0.0"),
        ]
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(
                cmp.compareVersion(lower, toVersion: higher) == .orderedAscending,
                "\(lower) should sort below \(higher)"
            )
        }
    }

    /// The sentinel must not be `.0`: the comparator ranks `0.9.0.0.9 > 0.9.0`,
    /// so padding stable with fewer components than beta inverts the order.
    /// Guards against someone "simplifying" 9999 away.
    @Test
    func stable_sentinel_outranks_every_beta_component() throws {
        let cmp = SUStandardVersionComparator()
        let stable = try runComparisonHelper("0.9.0")
        let highestBeta = try runComparisonHelper("0.9.0-beta.9998")
        #expect(cmp.compareVersion(highestBeta, toVersion: stable) == .orderedAscending)
    }

    @Test(arguments: [
        ("0.1.1", "0.1.2"),
        ("0.1.11", "0.1.12"),
        ("0.1.12", "0.1.13"),
        ("1.0.9", "1.0.10"),
    ])
    func bump_patch_increments_the_last_component(input: String, expected: String) throws {
        #expect(try runLibHelper("bump_patch_version", input) == expected)
    }

    /// MAS `CFBundleVersion` is at most three period-separated integers.
    @Test(arguments: [
        ("1.8.0", "1.8.0"),
        ("0.9.0-beta.1", "0.9.0"),
        ("0.1.21", "0.1.21"),
        ("0.0.0", "0.0.0"),
    ])
    func mas_bundle_version_is_at_most_three_components(input: String, expected: String) throws {
        let stamped = try runLibHelper("mas_bundle_version", input)
        #expect(stamped == expected)
        #expect(stamped.split(separator: ".").count <= 3)
        #expect(stamped.split(separator: ".").count >= 1)
    }

    @Test
    func build_mas_does_not_stamp_sparkle_comparison_version() throws {
        let script = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/build-mas.sh"),
            encoding: .utf8
        )
        #expect(script.contains("BUILD_NUMBER=\"$(mas_bundle_version \"$VERSION\")\""))
        #expect(!script.contains("BUILD_NUMBER=\"$(sparkle_comparison_version"))
        let build = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/build.sh"),
            encoding: .utf8
        )
        #expect(build.contains("BUILD_NUMBER=\"$(sparkle_comparison_version \"$VERSION\")\""))
    }

    /// Runs the real `sparkle_comparison_version` from scripts/_lib.sh.
    private func runComparisonHelper(_ version: String) throws -> String {
        try runLibHelper("sparkle_comparison_version", version)
    }

    private func runLibHelper(_ function: String, _ version: String) throws -> String {
        let lib = repoRoot().appendingPathComponent("scripts/_lib.sh").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \(lib); \(function) \(version)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func repoRoot() -> URL {
        // #filePath is <repo>/FuturaTermTests/App/UpdaterChannelTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
