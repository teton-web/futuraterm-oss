import Foundation
@testable import FuturaTerm
import Testing

/// Pins CGS `dlsym` names to `#if !APP_STORE` in `WindowAppearance.swift`.
/// Debug hosts compile the Direct path (eager `fatalError` if a symbol is missing).
@MainActor
struct WindowAppearanceSPITests {
    @Test
    func cgs_dlsym_sits_inside_not_app_store() throws {
        let source = try String(contentsOf: repoFile("FuturaTerm/Views/WindowAppearance.swift"), encoding: .utf8)
        let gated = directOnlyRegions(in: source)
        #expect(gated.contains("CGSDefaultConnectionForThread"))
        #expect(gated.contains("CGSSetWindowBackgroundBlurRadius"))
        #expect(gated.contains("dlsym(handle, \"CGSDefaultConnectionForThread\")"))
        #expect(gated.contains("dlsym(handle, \"CGSSetWindowBackgroundBlurRadius\")"))
        #expect(gated.contains("fatalError(\"CGSDefaultConnectionForThread symbol not found\")"))
        #expect(gated.contains("fatalError(\"CGSSetWindowBackgroundBlurRadius symbol not found\")"))

        let masOnly = appStoreRegions(in: source)
        #expect(!masOnly.contains("CGSDefaultConnectionForThread"))
        #expect(!masOnly.contains("CGSSetWindowBackgroundBlurRadius"))
        #expect(!masOnly.contains("dlsym(handle"))
    }

    @Test
    func mas_titlebar_call_sites_skip_private_class_names() throws {
        let source = try String(contentsOf: repoFile("FuturaTerm/Views/WindowAppearance.swift"), encoding: .utf8)
        let masOnly = appStoreRegions(in: source)
        for name in [
            "NSTitlebarView",
            "NSTitlebarBackgroundView",
            "NSTitlebarContainerView",
            "NSScrollPocket",
        ] {
            #expect(!masOnly.contains("\"\(name)\""), "MAS must not walk \(name)")
        }
        let direct = directOnlyRegions(in: source)
        #expect(direct.contains("\"NSTitlebarView\""))
        #expect(direct.contains("\"NSTitlebarBackgroundView\""))
        #expect(direct.contains("\"NSScrollPocket\""))
    }

    @Test
    func debug_host_still_compiles_cgs_direct_path() {
        #expect(AppDistribution.isAppStore == false)
        #if APP_STORE
        Issue.record("Debug tests must compile the Direct CGS path, not APP_STORE")
        #endif
    }

    @Test
    func mas_skips_private_appkit_selectors() throws {
        let source = try String(contentsOf: repoFile("FuturaTerm/Views/WindowAppearance.swift"), encoding: .utf8)
        let masOnly = appStoreRegions(in: source)
        for selector in [
            "_canDoSidebarProactivePeek",
            "setRevealsOnEdgeHoverInFullscreen:",
            "_updateHasItemToRevealOnEdgeHover",
            "_cornerRadius",
        ] {
            #expect(!masOnly.contains(selector), "MAS must not compile \(selector)")
        }
        let direct = directOnlyRegions(in: source)
        #expect(direct.contains("_canDoSidebarProactivePeek"))
        #expect(direct.contains("setRevealsOnEdgeHoverInFullscreen:"))
        #expect(direct.contains("_updateHasItemToRevealOnEdgeHover"))
        #expect(direct.contains("_cornerRadius"))
    }

    /// Bodies compiled for Direct (`#if !APP_STORE` and `#else` of `#if APP_STORE`).
    private func directOnlyRegions(in source: String) -> String {
        extractIfRegions(in: source, capturingDirect: true)
    }

    /// Bodies compiled for MAS (`#if APP_STORE` and `#else` of `#if !APP_STORE`).
    private func appStoreRegions(in source: String) -> String {
        extractIfRegions(in: source, capturingDirect: false)
    }

    private func extractIfRegions(in source: String, capturingDirect: Bool) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [String] = []
        var depth = 0
        var capturing = false
        var current: [String] = []
        var kind: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "#if !APP_STORE" || trimmed == "#if APP_STORE" {
                if capturing { depth += 1
                    current.append(line)
                    continue
                }
                kind = trimmed
                capturing = true
                depth = 1
                let wantDirect = trimmed == "#if !APP_STORE"
                capturing = capturingDirect ? wantDirect : !wantDirect
                current = capturing ? [line] : []
                if !capturing { depth = 1 }
                continue
            }
            if kind != nil, trimmed.hasPrefix("#else") {
                if depth == 1 {
                    if capturing { chunks.append(current.joined(separator: "\n")) }
                    let wantDirect = kind == "#if APP_STORE"
                    capturing = capturingDirect ? wantDirect : !wantDirect
                    current = capturing ? [line] : []
                    continue
                }
            }
            if kind != nil, trimmed.hasPrefix("#endif") {
                depth -= 1
                if depth == 0 {
                    if capturing { current.append(line)
                        chunks.append(current.joined(separator: "\n"))
                    }
                    capturing = false
                    current = []
                    kind = nil
                    continue
                }
            } else if capturing, trimmed.hasPrefix("#if ") {
                depth += 1
            }
            if capturing { current.append(line) }
        }
        return chunks.joined(separator: "\n")
    }

    private func repoFile(_ relative: String) throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent("LICENSE").path) {
                return dir.appendingPathComponent(relative)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { throw TestError.missingRepoRoot }
            dir = parent
        }
    }

    private enum TestError: Error { case missingRepoRoot }
}
