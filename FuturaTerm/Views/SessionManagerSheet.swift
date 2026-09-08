import SwiftUI

/// Browse local zmx sessions: open one in FuturaTerm or kill the selection.
struct SessionManagerSheet: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @Environment(GrokSessionStore.self)
    private var grokSessions
    @Environment(\.dismiss)
    private var dismiss

    @State
    private var selection: Set<String> = []
    @State
    private var isKillConfirmPresented = false
    @State
    private var inlineError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ChromeDialogAccessibility.sessions)
                .font(.headline)
                .accessibilityHidden(true)
            content
            if let inlineError {
                Text(inlineError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if selection.count == 1, !appState.zmx.isBundled() {
                Text(ChromeDialogAccessibility.zmxNotAvailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(ChromeDialogAccessibility.kill) { isKillConfirmPresented = true }
                    .disabled(selection.isEmpty)
                    .accessibilityLabel(ChromeDialogAccessibility.kill)
                Spacer()
                Button(ChromeDialogAccessibility.openInDefaultTerminal) { openExternally() }
                    .disabled(!canOpenExternally)
                    .accessibilityLabel(ChromeDialogAccessibility.openInDefaultTerminal)
                    .help(
                        appState.zmx.isBundled()
                            ? ChromeDialogAccessibility.openInDefaultTerminal
                            : ChromeDialogAccessibility.zmxNotAvailable
                    )
                Button(ChromeDialogAccessibility.openInFuturaTerm) { openSelected() }
                    .disabled(selection.count != 1)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(ChromeDialogAccessibility.openInFuturaTerm)
                Button(ChromeDialogAccessibility.cancel, role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(ChromeDialogAccessibility.cancel)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 280)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChromeDialogAccessibility.sessions)
        .accessibilityAddTraits(.isModal)
        .alert(killAlertTitle, isPresented: $isKillConfirmPresented) {
            Button(ChromeDialogAccessibility.cancel, role: .cancel) {}
                .accessibilityLabel(ChromeDialogAccessibility.cancel)
            Button(ChromeDialogAccessibility.kill, role: .destructive) {
                Task { await confirmKill() }
            }
            .accessibilityLabel(ChromeDialogAccessibility.kill)
        } message: {
            Text(killAlertMessage)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .zmxSessionsChanged)) { _ in
            Task { await refresh() }
        }
    }

    private var killAlertTitle: String {
        ChromeDialogAccessibility.killSessionsTitle(count: selection.count)
    }

    private var killAlertMessage: String {
        let names = selectedRows.map(\.name)
        let attached = selectedRows.contains { $0.attachment == .attached }
        return ChromeDialogAccessibility.killSessionsMessage(names: names, includesAttached: attached)
    }

    private var selectedRows: [SessionInventory.Row] {
        appState.sessionInventoryRows.filter { selection.contains($0.name) }
    }

    private var canOpenExternally: Bool {
        selection.count == 1 && appState.zmx.isBundled()
    }

    @ViewBuilder
    private var content: some View {
        if appState.isSessionInventoryLoading, appState.sessionInventoryRows.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.sessionInventoryUnavailable {
            Text("Session listing unavailable")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.sessionInventoryRows.isEmpty {
            Text("No terminal sessions")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(appState.sessionInventoryRows, id: \.name) { row in
                    sessionRow(row)
                        .tag(row.name)
                        .onTapGesture(count: 2) {
                            selection = [row.name]
                            openSelected()
                        }
                }
            }
            .frame(minHeight: 180)
        }
    }

    private func sessionRow(_ row: SessionInventory.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
                .font(.body)
            HStack(spacing: 8) {
                Text(statusCopy(row))
                if row.kind == .futuraterm, row.attachment == .attached, let project = row.claim?.projectName, !project.isEmpty {
                    Text(project)
                }
                if row.kind == .futuraterm, row.attachment == .unattached, let suggested = row.suggestedProjectName {
                    Text("Suggested: \(suggested)")
                }
                Text(clientsCopy(row.clients))
                if let foreground = row.foregroundName, !foreground.isEmpty {
                    Text(foreground)
                }
                if AgentIcon.match(processName: row.foregroundName) == .grok,
                   let glance = grokSessions.glanceLabel(for: row.name)
                {
                    Text(glance)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .modifier(OptionalHelp(text: grokSessions.detailLine(for: row.name)))
        .task(id: "\(row.name):\(row.foregroundName ?? "")") {
            guard AgentIcon.match(processName: row.foregroundName) == .grok else { return }
            let pid = ZmxForegroundResolver.foregroundPID(sessionName: row.name)
            grokSessions.resolve(
                sessionName: row.name,
                pid: pid,
                cwd: pid.flatMap { ProcessInspector.workingDirectory(pid: $0) }
            )
        }
    }

    private func statusCopy(_ row: SessionInventory.Row) -> String {
        switch (row.kind, row.attachment) {
        case (.foreign, _): "Other"
        case (.futuraterm, .attached): "In FuturaTerm"
        case (.futuraterm, .unattached): "Not in a project"
        }
    }

    private func clientsCopy(_ clients: Int?) -> String {
        if let clients {
            "clients:\(clients)"
        } else {
            "clients:?"
        }
    }

    private func refresh() async {
        await appState.refreshSessionInventory(projects: projectStore.projects)
    }

    private func confirmKill() async {
        let names = Array(selection)
        await appState.killInventorySessions(names, projects: projectStore.projects)
        selection.subtract(Set(names))
        await refresh()
    }

    private func openExternally() {
        guard canOpenExternally, let name = selection.first else { return }
        let opened = ExternalZmxAttach.open(
            sessionName: name,
            zmxURL: ExternalZmxAttach.bundledZmxURL()
        )
        if opened {
            inlineError = nil
        } else if ExternalZmxAttach.bundledZmxURL() == nil {
            inlineError = ChromeDialogAccessibility.zmxNotAvailable
        }
    }

    private func openSelected() {
        guard selection.count == 1, let name = selection.first else { return }
        switch appState.openInventorySession(name, projects: projectStore.projects) {
        case .focused,
             .attached:
            inlineError = nil
            dismiss()
            appState.restoreFocusToActivePane()
        case .needsLocalProject:
            inlineError = ChromeDialogAccessibility.needsLocalProject
            appState.presentToast(ChromeDialogAccessibility.needsLocalProject)
        case .notFound:
            inlineError = ChromeDialogAccessibility.sessionNotFound
            appState.presentToast(ChromeDialogAccessibility.sessionNotFound)
        }
    }
}
