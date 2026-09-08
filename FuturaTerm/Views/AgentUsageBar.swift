import AppKit
import SwiftUI

/// Sidebar footer chip: email (or "Grok") while authenticated. Clicking
/// presents a native popover with the account header and, when usage is
/// enabled, the existing quota row.
struct SidebarAccountRow: View {
    let account: AgentAccount
    let snapshot: AgentUsageSnapshot?
    var showUsage: Bool

    @Environment(GitHubAvatarStore.self)
    private var githubAvatar
    @State
    private var isPopoverPresented = false
    @AppStorage(Preferences.Keys.sidebarIconSize)
    private var iconSizeRaw = SidebarIconSize.medium.rawValue
    @ScaledMetric(relativeTo: .body)
    private var agentIconSize: CGFloat = 15

    private var iconSide: CGFloat {
        let size = SidebarIconSize(rawValue: iconSizeRaw) ?? .medium
        return agentIconSize * size.glyphScale
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                if let avatar = githubAvatar.image {
                    Image(nsImage: avatar)
                        .resizable()
                        .scaledToFill()
                        .frame(width: iconSide, height: iconSide)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                }
                FadingText(account.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(account.label)
        .accessibilityLabel(account.label)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(account.kind.agentIcon.rawValue)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSide, height: iconSide)
                    .foregroundStyle(account.kind.agentIcon.brandColor)
                Text(account.label)
                    .font(.body)
                    .lineLimit(1)
            }
            if showUsage {
                if let snapshot {
                    AgentUsageFooterRow(snapshot: snapshot)
                } else {
                    Text("Usage unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 260, alignment: .leading)
    }
}

struct AgentUsageFooterRow: View {
    let snapshot: AgentUsageSnapshot
    @AppStorage(Preferences.Keys.sidebarIconSize)
    private var iconSizeRaw = SidebarIconSize.medium.rawValue
    /// Same 15pt body-relative metric as `SidebarRowIcon`, scaled by the
    /// sidebar icon-size preference.
    @ScaledMetric(relativeTo: .body)
    private var agentIconSize: CGFloat = 15

    private var iconSide: CGFloat {
        let size = SidebarIconSize(rawValue: iconSizeRaw) ?? .medium
        return agentIconSize * size.glyphScale
    }

    var body: some View {
        Button(action: openUsage) {
            HStack(spacing: 8) {
                Image(snapshot.kind.agentIcon.rawValue)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSide, height: iconSide)
                    .foregroundStyle(snapshot.kind.agentIcon.brandColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(snapshot.kind.displayName)  \(snapshot.remainingPercent)% left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: snapshot.usedFraction)
                        .progressViewStyle(.linear)
                        .tint(barColor)
                        .controlSize(.small)
                    if let caption = AgentUsage.resetCaption(periodEnd: snapshot.periodEnd) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var barColor: Color {
        snapshot.remainingPercent < 15 ? FuturaTermTheme.warning : FuturaTermTheme.accent
    }

    private var helpText: String {
        var parts: [String] = []
        if let caption = AgentUsage.resetCaption(periodEnd: snapshot.periodEnd) {
            parts.append(caption)
        } else {
            parts.append("\(snapshot.kind.displayName) usage")
        }
        if snapshot.isStale {
            parts.append("Usage may be out of date")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var text = "\(snapshot.kind.displayName) usage, \(snapshot.remainingPercent) percent remaining"
        if let caption = AgentUsage.resetCaption(periodEnd: snapshot.periodEnd) {
            text += ", \(caption)"
        }
        if snapshot.isStale {
            text += ", usage may be out of date"
        }
        return text
    }

    private func openUsage() {
        NSWorkspace.shared.open(snapshot.kind.usageURL)
    }
}
