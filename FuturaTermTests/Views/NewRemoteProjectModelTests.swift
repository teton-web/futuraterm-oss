@testable import FuturaTerm
import Testing

@MainActor
struct NewRemoteProjectModelTests {
    @Test
    func select_online_device_fills_magicdns_host_and_composes_tilde() throws {
        let model = NewRemoteProjectModel(isLoading: false)
        let onlineA = device(id: "a", hostName: "box", dnsName: "box.tailnet.ts.net", online: true)
        let onlineB = device(id: "b", hostName: "lab", dnsName: "lab.tailnet.ts.net", online: true)
        let offline = device(id: "c", hostName: "old", dnsName: "old.tailnet.ts.net", online: false)
        model.applySnapshot(.ready(devices: [onlineA, onlineB, offline], selfHostName: "macbook"))
        #expect(model.devices.count == 3)
        #expect(model.devices.filter(\.online).count == 2)
        #expect(model.devices.contains { !$0.online })

        #expect(model.step == .device)
        model.selectDevice(onlineA)
        #expect(model.host == onlineA.sshHost)
        #expect(model.host == "box.tailnet.ts.net")
        #expect(!model.host.contains("@"))
        #expect(model.selectedDeviceID == "a")
        #expect(model.step == .directory)
        #expect(model.name.isEmpty)
        let composed = try #require(model.composedPath)
        #expect(composed == "box.tailnet.ts.net:~")
        #expect(ProjectPath.composeRemote(host: onlineA.sshHost, directory: "~") == composed)
    }

    @Test
    func select_offline_device_leaves_host_unchanged() {
        let model = NewRemoteProjectModel(host: "kept", isLoading: false)
        let online = device(id: "a", hostName: "box", dnsName: "box.tailnet.ts.net", online: true)
        let offline = device(id: "c", hostName: "old", dnsName: "old.tailnet.ts.net", online: false)
        model.applySnapshot(.ready(devices: [online, offline], selfHostName: nil))
        model.selectDevice(offline)
        #expect(model.host == "kept")
        #expect(model.selectedDeviceID == nil)
    }

    @Test
    func unavailable_not_installed_reveals_manual_host() {
        let model = NewRemoteProjectModel()
        model.applySnapshot(.unavailable(.notInstalled))
        #expect(model.showsManualHost)
        #expect(model.showsHostField)
        #expect(!model.isLoading)
    }

    @Test
    func ready_empty_shows_manual_host_fields() {
        let model = NewRemoteProjectModel()
        model.applySnapshot(.ready(devices: [], selfHostName: nil))
        #expect(model.showsHostField)
        #expect(model.devices.isEmpty)
        #expect(model.step == .device)
    }

    @Test
    func enter_host_manually_reveals_host_while_list_stays() {
        let model = NewRemoteProjectModel(isLoading: false)
        let online = device(id: "a", hostName: "box", dnsName: "box.tailnet.ts.net", online: true)
        model.applySnapshot(.ready(devices: [online], selfHostName: nil))
        #expect(!model.showsHostField)
        model.revealManualHost()
        #expect(model.showsManualHost)
        #expect(model.showsHostField)
        #expect(model.devices.count == 1)
    }

    @Test
    func manual_host_and_directory_compose_remote_path() {
        let model = NewRemoteProjectModel(host: "devbox", directory: "~/dev", isLoading: false)
        #expect(model.composedPath == "devbox:~/dev")
        #expect(ProjectPath.composeRemote(host: "devbox", directory: "~/dev") == "devbox:~/dev")
    }

    @Test
    func add_stays_disabled_until_directory_composes() {
        let model = NewRemoteProjectModel(host: "box", directory: "", isLoading: false)
        #expect(model.composedPath == nil)
        model.directory = "~"
        #expect(model.composedPath == "box:~")
    }

    @Test
    func go_back_keeps_directory_and_name() {
        let model = NewRemoteProjectModel(isLoading: false)
        let online = device(id: "a", hostName: "box", dnsName: "box.tailnet.ts.net", online: true)
        model.applySnapshot(.ready(devices: [online], selfHostName: nil))
        model.selectDevice(online)
        model.name = "api"
        model.directory = "~/dev"
        model.goBackToDevices()
        #expect(model.step == .device)
        #expect(model.selectedDeviceID == nil)
        #expect(model.name == "api")
        #expect(model.directory == "~/dev")
        #expect(model.host == "box.tailnet.ts.net")

        model.selectDevice(online)
        #expect(model.selectedDeviceID == "a")
        #expect(model.step == .directory)
        #expect(model.name == "api")
        #expect(model.directory == "~/dev")
        #expect(model.host == "box.tailnet.ts.net")
    }

    @Test
    func existing_projects_match_magicdns_hostname_and_ignore_user() {
        let model = NewRemoteProjectModel(isLoading: false)
        let online = device(id: "a", hostName: "box", dnsName: "box.tailnet.ts.net", online: true)
        model.applySnapshot(.ready(devices: [online], selfHostName: nil))
        model.selectDevice(online)
        let magic = Project(name: "magic", path: "box.tailnet.ts.net:~/a")
        let hostName = Project(name: "short", path: "box:~/b")
        let user = Project(name: "user", path: "me@box.tailnet.ts.net:~/c")
        let prefix = Project(name: "prefix", path: "box.tailnet.ts.net.other:~/d")
        let local = Project(name: "local", path: "/Users/me/dev")
        let other = Project(name: "other", path: "lab:~/e")
        let found = model.existingProjects(in: [magic, hostName, user, prefix, local, other])
        #expect(found.map(\.name) == ["magic", "short", "user"])
        #expect(NewRemoteProjectModel.matches(magic, device: online))
        #expect(NewRemoteProjectModel.matches(hostName, device: online))
        #expect(NewRemoteProjectModel.matches(user, device: online))
        #expect(!NewRemoteProjectModel.matches(prefix, device: online))
        #expect(!NewRemoteProjectModel.matches(local, device: online))
        #expect(!NewRemoteProjectModel.matches(other, device: online))
    }

    @Test
    func manual_path_ignores_step_and_does_not_need_device() {
        let model = NewRemoteProjectModel(host: "devbox", directory: "~/dev", isLoading: false)
        model.revealManualHost()
        #expect(model.showsManualHost)
        #expect(model.step == .device)
        #expect(model.composedPath == "devbox:~/dev")
        #expect(model.existingProjects(in: [Project(name: "r", path: "devbox:~/dev")]).isEmpty)
    }

    private func device(
        id: String,
        hostName: String,
        dnsName: String,
        online: Bool
    ) -> TailscaleDevice {
        TailscaleDevice(
            id: id,
            hostName: hostName,
            dnsName: dnsName,
            os: "linux",
            online: online,
            isSelf: false,
            tailscaleIPs: ["100.64.0.2"]
        )
    }
}
