import Foundation

enum AgentUsageError: Error, Equatable {
    /// No usable login, expired credentials, or the billing API returned 401.
    case unauthenticated
    /// Transport failure, 404, empty body, or a non-success HTTP status.
    case unavailable
    /// JSON could not be turned into a quota snapshot (including `{config:null}`).
    case decodeFailed
}

protocol AgentUsageProvider: Sendable {
    var kind: AgentUsageKind { get }
    /// Filesystem/expiry only — must not hit the network.
    func isAuthenticated() -> Bool
    func fetch() async throws -> AgentUsageSnapshot
}
