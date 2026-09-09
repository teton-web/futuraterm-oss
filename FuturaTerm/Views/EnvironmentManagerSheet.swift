import SwiftUI

/// Browse local TCP LISTEN development servers: open, show, or kill selected listeners.
struct EnvironmentManagerSheet: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
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
            Text(ChromeDialogAccessibility.environments)
                .font(.headline)
                .accessibilityHidden(true)
            content
            if let inlineError {
                Text(inlineError)
                    .font(.caption)
                    .foregroundStyle(FuturaTermTheme.error)
            }
            HStack {
                Button(ChromeDialogAccessibility.kill) { isKillConfirmPresented = true }
                    .disabled(selection.isEmpty)
                    .accessibilityLabel(ChromeDialogAccessibility.kill)
                Spacer()
                Button(ChromeDialogAccessibility.openInBrowser) { openSelected() }
                    .disabled(!canOpen)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(ChromeDialogAccessibility.openInBrowser)
                Button(ChromeDialogAccessibility.showInFuturaTerm) { showSelected() }
                    .disabled(!canShow)
                    .accessibilityLabel(ChromeDialogAccessibility.showInFuturaTerm)
                Button(ChromeDialogAccessibility.cancel, role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(ChromeDialogAccessibility.cancel)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 280)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChromeDialogAccessibility.environments)
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
    }

    private var killAlertTitle: String {
        ChromeDialogAccessibility.killServerTitle(count: selection.count)
    }

    private var killAlertMessage: String {
        let lines = selectedRows.map { "\($0.command) · \($0.port)" }
        return ChromeDialogAccessibility.killServerMessage(lines: lines)
    }

    private var selectedRows: [LocalListenerInventory.Row] {
        appState.localListenerRows.filter { selection.contains($0.id) }
    }

    private var selectedID: String? {
        selection.count == 1 ? selection.first : nil
    }

    private var canOpen: Bool { selectedID != nil }

    private var canShow: Bool {
        guard let id = selectedID else { return false }
        return appState.canShowLocalListenerInApp(id: id, projects: projectStore.projects)
    }

    @ViewBuilder
    private var content: some View {
        if appState.isLocalListenerLoading, appState.localListenerRows.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.localListenerUnavailable {
            Text("Server listing unavailable")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.localListenerRows.isEmpty {
            Text("No local development servers")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(appState.localListenerRows) { row in
                    listenerRow(row)
                        .tag(row.id)
                        .onTapGesture(count: 2) {
                            selection = [row.id]
                            openSelected()
                        }
                }
            }
            .frame(minHeight: 180)
        }
    }

    private func listenerRow(_ row: LocalListenerInventory.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(row.command) · \(row.port)")
                .font(.body)
            HStack(spacing: 8) {
                Text(row.displayURL)
                if let project = row.projectName, !project.isEmpty {
                    Text(project)
                }
                if let argv = row.argvSummary, !argv.isEmpty {
                    Text(argv)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func openSelected() {
        guard let id = selectedID else { return }
        switch appState.openLocalListenerInBrowser(id: id) {
        case .opened:
            inlineError = nil
        case .failed,
             .notFound:
            inlineError = ChromeDialogAccessibility.couldNotOpenAddress
        }
    }

    private func showSelected() {
        guard let id = selectedID else { return }
        let result = appState.showLocalListenerInApp(id: id, projects: projectStore.projects)
        guard result != .none else { return }
        dismiss()
        appState.restoreFocusToActivePane()
    }

    private func refresh() async {
        await appState.refreshLocalListeners(projects: projectStore.projects)
    }

    private func confirmKill() async {
        let ids = Array(selection)
        await appState.killLocalListeners(ids: ids, projects: projectStore.projects)
        selection.subtract(Set(ids))
    }
}
