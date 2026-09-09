import Foundation

/// Coding-agent account whose quota can appear in the sidebar footer.
/// Raw values are stable preference/log identifiers, not display names.
enum AgentUsageKind: String, Hashable {
    case grok

    var displayName: String {
        switch self {
        case .grok: "Grok"
        }
    }

    /// Bundled logo for this agent, matching tab-row detection.
    var agentIcon: AgentIcon {
        switch self {
        case .grok: .grok
        }
    }

    var usageURL: URL {
        switch self {
        case .grok:
            URL(string: "https://grok.com/?_s=usage")!
        }
    }
}

enum AgentUsage {
    /// Remaining quota as an integer percent. `usedFraction` is 0...1 **used**;
    /// values outside that range are clamped before rounding.
    static func remainingPercent(usedFraction: Double) -> Int {
        let clamped = min(1, max(0, usedFraction))
        let value = Int((100 - (clamped * 100)).rounded())
        return min(100, max(0, value))
    }

    /// Local-timezone caption for the usage window end, or `nil` when unknown.
    static func resetCaption(
        periodEnd: Date?,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let periodEnd else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(locale)
        style.timeZone = timeZone
        return "Resets \(periodEnd.formatted(style))"
    }
}

/// Signed-in coding-agent account shown in the sidebar footer chip.
struct AgentAccount: Equatable, Hashable, Identifiable {
    var id: AgentUsageKind { kind }

    var kind: AgentUsageKind
    /// Email when the auth file has one; otherwise `kind.displayName`.
    var label: String
}

/// Last successfully decoded (or stale) quota snapshot for one agent.
struct AgentUsageSnapshot: Equatable, Hashable, Identifiable {
    var id: AgentUsageKind { kind }

    var kind: AgentUsageKind
    /// Fraction of the current window that has been **used**, 0...1.
    var usedFraction: Double
    var remainingPercent: Int
    var periodEnd: Date?
    var fetchedAt: Date
    var isStale: Bool

    init(
        kind: AgentUsageKind,
        usedFraction: Double,
        periodEnd: Date?,
        fetchedAt: Date,
        isStale: Bool = false
    ) {
        let clamped = min(1, max(0, usedFraction))
        self.kind = kind
        self.usedFraction = clamped
        remainingPercent = AgentUsage.remainingPercent(usedFraction: clamped)
        self.periodEnd = periodEnd
        self.fetchedAt = fetchedAt
        self.isStale = isStale
    }
}
