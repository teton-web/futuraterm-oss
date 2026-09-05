import Foundation

/// Pure join of a zmx listing onto live panes and sidebar projects.
/// No process I/O — inspect and claims are injected.
enum SessionInventory {
    enum Kind: Equatable { case futuraterm, foreign }
    enum Attachment: Equatable { case attached, unattached }
    struct Claim: Equatable {
        var paneID: UUID
        var tabID: UUID
        var projectID: UUID
        var projectName: String
    }

    struct Row: Equatable {
        var name: String
        var clients: Int?
        var leaderPID: pid_t?
        var kind: Kind
        var attachment: Attachment
        var claim: Claim?
        var suggestedProjectName: String?
        var foregroundName: String?
    }

    static func rows(
        entries: [ZmxSessionListParser.Entry],
        leaders: [String: pid_t],
        claims: [String: Claim],
        projects: [Project],
        inspect: (String) -> (comm: String?, cwd: String?)
    ) -> [Row] {
        let mapped = entries.map { entry in
            row(for: entry, leaders: leaders, claims: claims, projects: projects, inspect: inspect)
        }
        return mapped.sorted(by: Self.rowSort)
    }

    private static func row(
        for entry: ZmxSessionListParser.Entry,
        leaders: [String: pid_t],
        claims: [String: Claim],
        projects: [Project],
        inspect: (String) -> (comm: String?, cwd: String?)
    ) -> Row {
        let kind: Kind = entry.name.hasPrefix(ZmxSessionName.prefix) ? .futuraterm : .foreign
        let claim = claims[entry.name]
        let attached = claim != nil
        let comm = inspect(entry.name).comm
        return Row(
            name: entry.name,
            clients: entry.clients,
            leaderPID: leaders[entry.name],
            kind: kind,
            attachment: attached ? .attached : .unattached,
            claim: claim,
            suggestedProjectName: attached ? nil : suggestedProjectName(for: entry.name, kind: kind, projects: projects),
            foregroundName: comm
        )
    }

    /// Unique name-slug only. Skip pinned, remote, empty/generic/quick slugs,
    /// and 0/≥2 matches. No cwd matching, no grok filter.
    private static func suggestedProjectName(for name: String, kind: Kind, projects: [Project]) -> String? {
        guard kind == .futuraterm,
              let slug = ZmxSessionName.slug(fromName: name),
              !slug.isEmpty,
              slug != ZmxSessionName.quickTerminalSlug,
              slug != ZmxSessionName.genericSlug
        else { return nil }

        let eligible = projects.filter { project in
            project.id != PinnedTabs.projectID && !project.isRemote
        }
        let slugMatches = eligible.filter { ZmxSessionName.slug($0.name) == slug }
        guard slugMatches.count == 1 else { return nil }
        return slugMatches[0].name
    }

    private static func rowSort(_ a: Row, _ b: Row) -> Bool {
        let ga = group(a)
        let gb = group(b)
        if ga != gb { return ga < gb }
        if ga == 0 {
            let pa = a.claim?.projectName ?? ""
            let pb = b.claim?.projectName ?? ""
            let projectCmp = pa.localizedCaseInsensitiveCompare(pb)
            if projectCmp != .orderedSame { return projectCmp == .orderedAscending }
        }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// 0 attached FuturaTerm, 1 unattached FuturaTerm, 2 foreign.
    private static func group(_ row: Row) -> Int {
        switch (row.kind, row.attachment) {
        case (.futuraterm, .attached): 0
        case (.futuraterm, .unattached): 1
        case (.foreign, _): 2
        }
    }
}
