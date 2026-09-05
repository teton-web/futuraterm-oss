import Foundation
@testable import FuturaTerm
import Testing

struct ExternalZmxAttachTests {
    @Test
    func shellSingleQuote_wrapsOrdinaryName() {
        #expect(ExternalZmxAttach.shellSingleQuote("futuraterm-api-abc") == "'futuraterm-api-abc'")
    }

    @Test
    func shellSingleQuote_rewritesInteriorApostrophe() {
        #expect(ExternalZmxAttach.shellSingleQuote("weird ' name") == "'weird '\"'\"' name'")
    }

    @Test
    func commandFileContents_quotesOrdinaryName() {
        let body = ExternalZmxAttach.commandFileContents(
            zmxPath: "/tmp/zmx",
            sessionName: "futuraterm-api-abc",
            zmxDir: "/var/tmp/zmx-dir"
        )
        #expect(body.hasPrefix("#!/bin/sh\n"))
        #expect(body.contains("export ZMX_DIR='/var/tmp/zmx-dir'\n"))
        #expect(body.contains("exec '/tmp/zmx' attach 'futuraterm-api-abc'\n"))
        #expect(!body.contains("$(uname)"))
    }

    @Test
    func commandFileContents_quotesApostropheName() {
        let body = ExternalZmxAttach.commandFileContents(
            zmxPath: "/tmp/zmx",
            sessionName: "weird ' name",
            zmxDir: "/var/tmp/zmx-dir"
        )
        #expect(body.contains("exec '/tmp/zmx' attach 'weird '\"'\"' name'\n"))
    }

    @Test
    func commandFileContents_quotesCommandSubstitutionName() {
        let body = ExternalZmxAttach.commandFileContents(
            zmxPath: "/tmp/zmx",
            sessionName: "$(uname)",
            zmxDir: "/var/tmp/zmx-dir"
        )
        #expect(body.contains("exec '/tmp/zmx' attach '$(uname)'\n"))
        #expect(!body.contains("attach $(uname)"))
    }

    @Test
    func commandFileContents_quotesZmxDirWithApostrophe() {
        let body = ExternalZmxAttach.commandFileContents(
            zmxPath: "/tmp/zmx",
            sessionName: "s",
            zmxDir: "/tmp/zmx'dir"
        )
        #expect(body.contains("export ZMX_DIR='/tmp/zmx'\"'\"'dir'\n"))
    }

    @Test
    @MainActor
    func open_missingZmxURL_returnsFalse() {
        #expect(ExternalZmxAttach.open(sessionName: "futuraterm-api-abc", zmxURL: nil) == false)
    }
}
