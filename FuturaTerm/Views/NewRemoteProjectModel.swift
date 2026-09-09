import Foundation
import Observation

/// Draft state for the Remote Machine sheet. Tailscale path is two-step
/// (device, then directory). Manual host stays one page.
@MainActor
@Observable
final class NewRemoteProjectModel {
    enum Step: Equatable {
        case device
        case directory
    }

    var name: String
    var host: String
    var directory: String
    var zmxPath: String
    var snapshot: TailscaleSnapshot?
    var isLoading: Bool
    var showsManualHost: Bool
    var selectedDeviceID: String?
    var step: Step

    init(
        name: String = "",
        host: String = "",
        directory: String = "~",
        zmxPath: String = "",
        snapshot: TailscaleSnapshot? = nil,
        isLoading: Bool = true,
        showsManualHost: Bool = false
    ) {
        self.name = name
        self.host = host
        self.directory = directory
        self.zmxPath = zmxPath
        self.snapshot = snapshot
        self.isLoading = isLoading
        self.showsManualHost = showsManualHost
        selectedDeviceID = nil
        step = .device
    }

    var composedPath: String? {
        ProjectPath.composeRemote(host: host, directory: directory)
    }

    var trimmedZmxPath: String? {
        let trimmed = zmxPath.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    var devices: [TailscaleDevice] {
        if case let .ready(devices, _) = snapshot { return devices }
        return []
    }

    /// Host field is always available when Tailscale is missing, empty, or
    /// the user opted in. A populated ready list keeps it hidden until then.
    var showsHostField: Bool {
        if showsManualHost { return true }
        switch snapshot {
        case .unavailable:
            return true
        case let .ready(devices, _) where devices.isEmpty:
            return true
        default:
            return false
        }
    }

    func applySnapshot(_ snapshot: TailscaleSnapshot) {
        self.snapshot = snapshot
        isLoading = false
        if case .unavailable = snapshot {
            showsManualHost = true
        }
    }

    func selectDevice(_ device: TailscaleDevice) {
        guard device.online else { return }
        host = device.sshHost
        selectedDeviceID = device.id
        step = .directory
    }

    func goBackToDevices() {
        step = .device
        // List(selection:) does not re-fire for the same id; a one-device
        // tailnet would otherwise be stuck after Back.
        selectedDeviceID = nil
    }

    var selectedDevice: TailscaleDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    func existingProjects(in projects: [Project]) -> [Project] {
        guard let device = selectedDevice else { return [] }
        return projects.filter { Self.matches($0, device: device) }
    }

    /// Exact host match against MagicDNS (`sshHost`) or `hostName`, ignoring
    /// `user@`. Locals never match. Prefixes do not.
    static func matches(_ project: Project, device: TailscaleDevice) -> Bool {
        guard let host = ProjectPath.remoteHost(from: project.path) else { return false }
        let needle = host.lowercased()
        return needle == device.sshHost.lowercased() || needle == device.hostName.lowercased()
    }

    func revealManualHost() {
        showsManualHost = true
    }
}
