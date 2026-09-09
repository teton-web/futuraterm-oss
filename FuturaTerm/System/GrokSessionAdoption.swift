import Foundation

/// Pure matching for POR-372: place unclaimed grok-fronted `futuraterm-*`
/// zmx sessions into the unique sidebar project they belong to.
///
/// No process I/O. The gatherer turns a zmx listing + an inspect callback
/// into `Candidate`s; `assign` maps those onto projects. Ambiguous or
/// unmatched sessions are omitted — never a new `Project`.
enum GrokSessionAdoption {
    struct Candidate: Equatable {
        var sessionName: String
        var slug: String
        var cwd: String?
    }

    struct Assignment: Equatable {
        var sessionName: String
        var projectID: UUID
    }

    /// Unclaimed, grok-fronted sessions. Drops names already claimed by a
    /// pane, unknown client counts (`clients == nil` — same spare as the
    /// reaper), unparseable names, and processes that are not Grok.
    /// `clients == 0` and `clients > 0` both adopt: a stray attach client
    /// should still become a tab.
    static func candidates(
        from entries: [ZmxSessionListParser.Entry],
        claimed: Set<String>,
        inspect: (String) -> (comm: String?, cwd: String?)
    ) -> [Candidate] {
        entries.compactMap { entry in
            guard entry.clients != nil,
                  !claimed.contains(entry.name),
                  let slug = ZmxSessionName.slug(fromName: entry.name)
            else { return nil }
            let info = inspect(entry.name)
            guard AgentIcon.match(processName: info.comm) == .grok else { return nil }
            return Candidate(sessionName: entry.name, slug: slug, cwd: info.cwd)
        }
    }

    /// Unique name-slug first, then unique local cwd. Skip pinned, remote,
    /// the quick-terminal slug, empty slugs, and 0/≥2 matches.
    ///
    /// The generic `project` slug (non-ASCII name fallback) is too common to
    /// treat as identity — skip slug matching and use cwd only.
    static func assign(_ candidates: [Candidate], projects: [Project]) -> [Assignment] {
        let eligible = projects.filter { project in
            project.id != PinnedTabs.projectID && !project.isRemote
        }
        return candidates.compactMap { candidate in
            assignment(for: candidate, eligible: eligible)
        }
    }

    private static func assignment(for candidate: Candidate, eligible: [Project]) -> Assignment? {
        guard !candidate.slug.isEmpty,
              candidate.slug != ZmxSessionName.quickTerminalSlug
        else { return nil }

        if candidate.slug != ZmxSessionName.genericSlug {
            let slugMatches = eligible.filter { ZmxSessionName.slug($0.name) == candidate.slug }
            if slugMatches.count == 1, let project = slugMatches.first {
                return Assignment(sessionName: candidate.sessionName, projectID: project.id)
            }
        }

        guard let cwd = candidate.cwd, !cwd.isEmpty else { return nil }
        let cwdMatches = eligible.filter { ProjectPath.matches($0.path, cwd) }
        guard cwdMatches.count == 1, let project = cwdMatches.first else { return nil }
        return Assignment(sessionName: candidate.sessionName, projectID: project.id)
    }
}
