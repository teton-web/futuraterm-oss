@testable import FuturaTerm
import Testing

struct DesktopViewTests {
    @Test
    func linux_os_hint_is_moonlight_for_that_host() {
        let plan = DesktopView.plan(
            host: "dts-3.tailnet.ts.net",
            osHint: "linux",
            moonlightAvailable: true,
            vncAvailable: true
        )
        #expect(plan == .moonlight(host: "dts-3.tailnet.ts.net"))
        #expect(
            DesktopView.action(for: plan)
                == .moonlight(arguments: ["stream", "dts-3.tailnet.ts.net", "Desktop"])
        )
        #expect(DesktopView.moonlightStreamArguments(host: "dts-3.tailnet.ts.net") == [
            "stream", "dts-3.tailnet.ts.net", DesktopView.sunshineDesktopApp,
        ])
        #expect(!DesktopView.moonlightStreamArguments(host: "box").contains { $0.contains("@") })
        #expect(DesktopView.moonlightPairArguments(host: "dts-3", pin: "4821") == [
            "pair", "dts-3", "--pin", "4821",
        ])
        #expect(DesktopView.moonlightPairArguments(host: "box", pin: "12") == nil)
        #expect(!(DesktopView.moonlightPairArguments(host: "dts-3", pin: "4821") ?? []).contains { $0.contains("@") })
        #expect(DesktopView.moonlightListArguments(host: "dts-3") == ["list", "dts-3"])
        #expect(DesktopView.makePairingPin(value: 5) == "0005")
        #expect(DesktopView.isValidPairingPin("0000"))
        #expect(!DesktopView.isValidPairingPin("12a4"))
        #expect(DesktopView.pairingClientName("dts-0.local") == "dts-0.local")
        #expect(DesktopView.pairingClientName("bad name!") == "badname")
        #expect(DesktopView.pairingClientName("***") == "Mac")
    }

    @Test
    func macos_os_hint_is_vnc_for_that_host() throws {
        let plan = DesktopView.plan(
            host: "dts-0.tailnet.ts.net",
            osHint: "macOS",
            moonlightAvailable: true,
            vncAvailable: true
        )
        #expect(plan == .vnc(host: "dts-0.tailnet.ts.net"))
        #expect(
            try DesktopView.action(for: plan)
                == .vnc(#require(URL(string: "vnc://dts-0.tailnet.ts.net")))
        )
    }

    @Test
    func linux_without_moonlight_is_missing_not_vnc_fallback() {
        let plan = DesktopView.plan(
            host: "omarchy",
            osHint: "linux",
            moonlightAvailable: false,
            vncAvailable: true
        )
        #expect(plan == .missing(reason: DesktopView.moonlightMissingReason))
        #expect(!DesktopView.moonlightMissingReason.lowercased().contains("brew"))
        #expect(!DesktopView.moonlightMissingReason.contains("omarchy-install"))
        #expect(!DesktopView.moonlightMissingReason.contains("ssh"))
        #expect(DesktopView.moonlightMissingReason.contains("this Mac"))
        #expect(DesktopView.moonlightLaunchFailedReason.contains("Sunshine"))
        #expect(!DesktopView.moonlightLaunchFailedReason.contains("ssh"))
    }

    @Test
    func unknown_os_leans_moonlight_not_silent_vnc() {
        let plan = DesktopView.plan(
            host: "mystery",
            osHint: nil,
            moonlightAvailable: true,
            vncAvailable: true
        )
        #expect(plan == .moonlight(host: "mystery"))
    }

    @Test
    func osHint_matches_tailscale_device_host() {
        let device = TailscaleDevice(
            id: "n1",
            hostName: "dts-3",
            dnsName: "dts-3.tailnet.ts.net",
            os: "linux",
            online: true,
            isSelf: false,
            tailscaleIPs: ["100.1.2.3"]
        )
        #expect(DesktopView.osHint(host: "dts-3.tailnet.ts.net", devices: [device]) == "linux")
        #expect(DesktopView.osHint(host: "dts-3", devices: [device]) == "linux")
        #expect(DesktopView.osHint(host: "other", devices: [device]) == nil)
    }
}
