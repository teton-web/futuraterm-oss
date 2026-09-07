import Foundation

/// Peer OS for View Desktop. Tailscale's `OS` string when we have it;
/// otherwise unknown — never inferred from the hostname.
enum DesktopPeerOS: Equatable {
    case linux
    case macOS
    case unknown

    static func fromHint(_ hint: String?) -> DesktopPeerOS {
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .unknown
        }
        let lower = raw.lowercased()
        if lower.contains("mac") || lower == "ios" || lower == "ipados" || lower.contains("darwin") {
            return .macOS
        }
        if lower.contains("linux") || lower.contains("android") {
            return .linux
        }
        return .unknown
    }
}

/// What View Desktop should hand off to. Never a pane, never an install.
enum DesktopLaunchPlan: Equatable {
    case moonlight(host: String)
    case vnc(host: String)
    case missing(reason: String)
}

/// Concrete handoff. Moonlight has no URL scheme — argv is
/// `stream <host> Desktop` (Sunshine's default app). VNC is Screen Sharing.
enum DesktopLaunchAction: Equatable {
    case moonlight(arguments: [String])
    case vnc(URL)
}

/// Pure host + OS hint → launch plan. NSWorkspace / gtk spawn stay outside.
enum DesktopView {
    static let moonlightMissingReason =
        "Moonlight is not installed. Install Moonlight to view this machine's screen."
    static let vncMissingReason =
        "A VNC viewer is not installed. Install a VNC viewer to view this machine's screen."
    static let notRemoteReason =
        "View Desktop is available on a remote project."

    /// moonlight-qt on macOS (Homebrew cask / official dmg).
    static let moonlightBundleIDs = [
        "com.moonlight-stream.Moonlight",
        "com.moonlight-stream.moonlight",
    ]

    /// Sunshine's default streamed app. moonlight-qt requires this positional.
    static let sunshineDesktopApp = "Desktop"

    /// `stream <host> Desktop` — argv after the Moonlight binary (no argv[0]).
    static func moonlightStreamArguments(host: String) -> [String] {
        ["stream", host, sunshineDesktopApp]
    }

    static func action(for plan: DesktopLaunchPlan) -> DesktopLaunchAction? {
        switch plan {
        case let .moonlight(host):
            .moonlight(arguments: moonlightStreamArguments(host: host))
        case let .vnc(host):
            URL(string: "vnc://\(host)").map { .vnc($0) }
        case .missing:
            nil
        }
    }

    static func plan(
        host: String,
        osHint: String?,
        moonlightAvailable: Bool,
        vncAvailable: Bool
    ) -> DesktopLaunchPlan {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .missing(reason: notRemoteReason)
        }
        switch DesktopPeerOS.fromHint(osHint) {
        case .macOS:
            guard vncAvailable else { return .missing(reason: vncMissingReason) }
            return .vnc(host: trimmed)
        case .linux,
             .unknown:
            // Unknown leans Moonlight (Omarchy). Do not silently vnc:// an
            // Omarchy box just because Screen Sharing exists on this Mac.
            guard moonlightAvailable else { return .missing(reason: moonlightMissingReason) }
            return .moonlight(host: trimmed)
        }
    }

    /// Match a project host to a Tailscale device's `OS` when the list is already in hand.
    static func osHint(host: String, devices: [TailscaleDevice]) -> String? {
        let needle = host.lowercased()
        return devices.first {
            $0.sshHost.lowercased() == needle || $0.hostName.lowercased() == needle
        }?.os
    }
}
