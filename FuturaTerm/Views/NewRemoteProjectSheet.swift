import SwiftUI

/// "New Project → Remote Machine" (#104 / POR-552): pick a Tailscale
/// device (fills SSH host) or type a host, plus directory. Add composes
/// the scp-style `Project.path`. No SSH probe, no pane spawn.
struct NewRemoteProjectSheet: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @Environment(\.dismiss)
    private var dismiss

    @State
    private var model = NewRemoteProjectModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ChromeDialogAccessibility.newRemoteProject)
                .font(.headline)
                .accessibilityHidden(true)
            if model.showsHostField {
                tailscaleSection
                projectFields(includeHost: true)
                enterHostManuallyButton
                helpCaption
                addBar(showBack: false, showAdd: true)
            } else if model.step == .directory {
                directoryStep
            } else {
                tailscaleSection
                enterHostManuallyButton
                helpCaption
                addBar(showBack: false, showAdd: false)
            }
        }
        .padding(20)
        .frame(width: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChromeDialogAccessibility.newRemoteProject)
        .accessibilityAddTraits(.isModal)
        .task {
            let snapshot = await TailscaleStatus.probe()
            model.applySnapshot(snapshot)
        }
    }

    @ViewBuilder
    private var tailscaleSection: some View {
        if model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 80)
        } else if case let .unavailable(reason) = model.snapshot {
            Text(unavailableCaption(reason))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(unavailableCaption(reason))
        } else if model.devices.isEmpty {
            Text(ChromeDialogAccessibility.tailscaleNoDevices)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .accessibilityLabel(ChromeDialogAccessibility.tailscaleNoDevices)
        } else {
            Text(ChromeDialogAccessibility.tailscaleDevices)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(ChromeDialogAccessibility.tailscaleDevices)
            List(selection: Binding(
                get: { model.selectedDeviceID },
                set: { newID in
                    guard let newID, let device = model.devices.first(where: { $0.id == newID }) else {
                        return
                    }
                    model.selectDevice(device)
                }
            )) {
                ForEach(model.devices) { device in
                    deviceRow(device)
                        .tag(device.id as String?)
                        .disabled(!device.online)
                }
            }
            .frame(minHeight: 140, maxHeight: 200)
        }
    }

    private func deviceRow(_ device: TailscaleDevice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(device.hostName)
            Text("\(device.os) · \(device.online ? "Online" : "Offline")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(device.hostName)
        .accessibilityValue("\(device.os), \(device.online ? "Online" : "Offline")")
    }

    @ViewBuilder
    private var directoryStep: some View {
        if let device = model.selectedDevice {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.hostName)
                    .font(.headline)
                Text(device.sshHost)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(ChromeDialogAccessibility.chooseDirectory)
        }
        projectFields(includeHost: false)
        existingProjectsSection
        helpCaption
        addBar(showBack: true, showAdd: true)
    }

    private var enterHostManuallyButton: some View {
        Button(ChromeDialogAccessibility.enterHostManually) {
            model.revealManualHost()
        }
        .disabled(model.showsHostField)
        .accessibilityLabel(ChromeDialogAccessibility.enterHostManually)
    }

    private var helpCaption: some View {
        Text(
            "Panes run persistent zmx sessions on the host over ssh — zmx must be installed there. "
                + "If it isn't found automatically, set an absolute path (e.g. ~/bin/zmx or /usr/local/bin/zmx). "
                + "Port, identity, and ControlMaster come from ~/.ssh/config."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func projectFields(includeHost: Bool) -> some View {
        Form {
            TextField(
                "Name",
                text: $model.name,
                prompt: Text(model.host.isEmpty ? "devbox" : model.host)
            )
            if includeHost {
                TextField("Host", text: $model.host, prompt: Text("[user@]host or ssh alias"))
            }
            TextField("Directory", text: $model.directory, prompt: Text("~/dev/api"))
            TextField("zmx path (optional)", text: $model.zmxPath, prompt: Text("auto-detect via PATH"))
        }
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private var existingProjectsSection: some View {
        let existing = model.existingProjects(in: projectStore.projects)
        if !existing.isEmpty {
            Text(ChromeDialogAccessibility.openExisting)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(ChromeDialogAccessibility.openExisting)
            ForEach(existing) { project in
                Button {
                    openExisting(project)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                        Text(project.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(project.name)
            }
        }
    }

    private func addBar(showBack: Bool, showAdd: Bool) -> some View {
        HStack {
            if showBack {
                Button(ChromeDialogAccessibility.back) {
                    model.goBackToDevices()
                }
                .accessibilityLabel(ChromeDialogAccessibility.back)
            }
            Spacer()
            Button(ChromeDialogAccessibility.cancel, role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(ChromeDialogAccessibility.cancel)
            if showAdd {
                Button(ChromeDialogAccessibility.add) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.composedPath == nil)
                    .accessibilityLabel(ChromeDialogAccessibility.add)
            }
        }
    }

    private func unavailableCaption(_ reason: TailscaleUnavailableReason) -> String {
        switch reason {
        case .notInstalled:
            ChromeDialogAccessibility.tailscaleUnavailableNotInstalled
        case .needsLogin:
            ChromeDialogAccessibility.tailscaleUnavailableNeedsLogin
        case .stopped:
            ChromeDialogAccessibility.tailscaleUnavailableStopped
        case .error:
            ChromeDialogAccessibility.tailscaleUnavailableError
        }
    }

    private func add() {
        guard let path = model.composedPath else { return }
        let trimmedName = model.name.trimmingCharacters(in: .whitespaces)
        appState.addOrSelectProject(
            store: projectStore,
            name: trimmedName.isEmpty ? model.host.trimmingCharacters(in: .whitespaces) : trimmedName,
            path: path,
            zmxPath: model.trimmedZmxPath
        )
        dismiss()
    }

    private func openExisting(_ project: Project) {
        appState.selectProject(project)
        dismiss()
    }
}
