import Foundation
@testable import FuturaTerm
import Testing

@MainActor
struct AgentUsageStoreTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(usedFraction: Double = 0.4, isStale: Bool = false) -> AgentUsageSnapshot {
        AgentUsageSnapshot(
            kind: .grok,
            usedFraction: usedFraction,
            periodEnd: nil,
            fetchedAt: fetchedAt,
            isStale: isStale
        )
    }

    @Test
    func success_publishes_snapshot() async {
        let stub = StubUsageProvider(snapshot: snapshot())
        let store = makeStore(provider: stub)
        await store.refresh()
        #expect(store.snapshots.count == 1)
        #expect(store.snapshots.first?.remainingPercent == 60)
        #expect(stub.fetchCount.value == 1)
    }

    @Test
    func unauthenticated_skips_fetch_and_removes_snapshot() async {
        let stub = StubUsageProvider(snapshot: snapshot())
        let store = makeStore(provider: stub)
        await store.refresh()
        #expect(!store.snapshots.isEmpty)
        let fetches = stub.fetchCount.value

        stub.authenticated = false
        await store.refresh()
        #expect(store.snapshots.isEmpty)
        #expect(stub.fetchCount.value == fetches)
    }

    @Test
    func never_authenticated_does_not_fetch() async {
        let stub = StubUsageProvider(snapshot: snapshot())
        stub.authenticated = false
        let store = makeStore(provider: stub)
        await store.refresh()
        #expect(stub.fetchCount.value == 0)
        #expect(store.snapshots.isEmpty)
    }

    @Test
    func fetch_401_removes_snapshot() async {
        let stub = StubUsageProvider(snapshot: snapshot())
        let store = makeStore(provider: stub)
        await store.refresh()
        #expect(!store.snapshots.isEmpty)
        #expect(stub.authenticated)

        stub.error = .unauthenticated
        await store.refresh()
        #expect(store.snapshots.isEmpty)
        #expect(stub.authenticated)
        #expect(stub.fetchCount.value == 2)
    }

    @Test
    func unavailable_keeps_previous_marked_stale() async {
        let stub = StubUsageProvider(snapshot: snapshot())
        let store = makeStore(provider: stub)
        await store.refresh()
        #expect(store.snapshots.first?.isStale == false)

        stub.error = .unavailable
        await store.refresh()
        #expect(store.snapshots.count == 1)
        #expect(store.snapshots.first?.isStale == true)
        #expect(store.snapshots.first?.usedFraction == 0.4)
    }

    @Test
    func decode_failed_keeps_previous_marked_stale_then_success_clears() async {
        let stub = StubUsageProvider(snapshot: snapshot())
        let store = makeStore(provider: stub)
        await store.refresh()

        stub.error = .decodeFailed
        await store.refresh()
        #expect(store.snapshots.first?.isStale == true)

        stub.error = nil
        stub.snapshot = snapshot(usedFraction: 0.2)
        await store.refresh()
        #expect(store.snapshots.first?.isStale == false)
        #expect(store.snapshots.first?.usedFraction == 0.2)
    }

    @Test
    func show_agent_usage_false_skips_fetch() async {
        let stub = StubUsageProvider(snapshot: snapshot())
        let store = makeStore(provider: stub, isUsageEnabled: { false })
        await store.refresh()
        #expect(stub.fetchCount.value == 0)
        #expect(store.snapshots.isEmpty)
    }

    @Test
    func enabling_usage_fetches_without_activation() async {
        let stub = StubUsageProvider(snapshot: snapshot())
        let enabled = LockedBox(false)
        let store = makeStore(provider: stub, isUsageEnabled: { enabled.value })
        store.start()
        #expect(stub.fetchCount.value == 0)

        enabled.mutate { $0 = true }
        await store.noteUsagePreferenceChanged()
        #expect(stub.fetchCount.value == 1)
        #expect(store.snapshots.count == 1)

        enabled.mutate { $0 = false }
        await store.noteUsagePreferenceChanged()
        #expect(stub.fetchCount.value == 1)
    }

    @Test
    func benchmark_gate_skips_fetch() async {
        let stub = StubUsageProvider(snapshot: snapshot())
        let store = makeStore(provider: stub, isBenchmarkEnabled: { true })
        store.start()
        await store.refresh()
        #expect(stub.fetchCount.value == 0)
        #expect(store.snapshots.isEmpty)
    }

    @Test
    func hosted_test_run_gate_skips_fetch() async {
        let stub = StubUsageProvider(snapshot: snapshot())
        let store = makeStore(provider: stub, isTestRun: { true })
        store.start()
        await store.refresh()
        #expect(stub.fetchCount.value == 0)
        #expect(store.snapshots.isEmpty)
    }

    private func makeStore(
        provider: StubUsageProvider,
        isBenchmarkEnabled: @escaping () -> Bool = { false },
        isTestRun: @escaping () -> Bool = { false },
        isUsageEnabled: @escaping () -> Bool = { true }
    ) -> AgentUsageStore {
        AgentUsageStore(
            providers: [provider],
            isBenchmarkEnabled: isBenchmarkEnabled,
            isTestRun: isTestRun,
            isUsageEnabled: isUsageEnabled,
            isAppActive: { true },
            isAnyWindowVisible: { true }
        )
    }
}

private final class StubUsageProvider: AgentUsageProvider, @unchecked Sendable {
    let kind: AgentUsageKind = .grok
    var authenticated = true
    var error: AgentUsageError?
    var snapshot: AgentUsageSnapshot?
    let fetchCount = LockedBox(0)

    init(snapshot: AgentUsageSnapshot) {
        self.snapshot = snapshot
    }

    func isAuthenticated() -> Bool {
        authenticated
    }

    func fetch() async throws -> AgentUsageSnapshot {
        fetchCount.mutate { $0 += 1 }
        if let error {
            throw error
        }
        if let snapshot {
            return snapshot
        }
        throw AgentUsageError.unavailable
    }
}
