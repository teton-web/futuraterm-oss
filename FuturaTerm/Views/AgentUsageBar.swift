import AppKit
import SwiftUI

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
        if let periodEnd = snapshot.periodEnd {
            parts.append("Resets \(periodEnd.formatted(date: .abbreviated, time: .omitted))")
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
        if snapshot.isStale {
            text += ", usage may be out of date"
        }
        return text
    }

    private func openUsage() {
        NSWorkspace.shared.open(snapshot.kind.usageURL)
    }
}
