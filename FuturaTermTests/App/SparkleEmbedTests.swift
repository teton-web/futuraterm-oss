import Foundation
@testable import FuturaTerm
import Testing

/// Direct embed must find Sparkle.framework during `xcodebuild archive`, not
/// only during a normal Release build. `$BUILD_DIR/../../SourcePackages` is
/// DerivedData/SourcePackages for the latter and ArchiveIntermediates/SourcePackages
/// for the former — which is how v0.1.22's first archive died.
struct SparkleEmbedTests {
    @Test
    func script_strips_sparkle_load_commands_on_app_store() throws {
        let script = try String(contentsOf: repoFile("scripts/embed-sparkle.sh"), encoding: .utf8)
        #expect(script.contains("strip-sparkle-dylib.py"))
        #expect(script.contains("ArchiveIntermediates"))
        #expect(!script.contains(#"echo "$BUILD_DIR"/../../SourcePackages"#))
    }

    @Test
    func finds_artifact_when_build_dir_is_a_normal_products_dir() throws {
        let root = try layout()
        defer { try? FileManager.default.removeItem(at: root) }
        let buildDir = root.appendingPathComponent("Build/Products")
        let found = try find(env: ["BUILD_DIR": buildDir.path, "SRCROOT": root.path])
        #expect(found == artifactPath(root: root))
    }

    @Test
    func finds_artifact_when_build_dir_is_an_archive_products_path() throws {
        let root = try layout()
        defer { try? FileManager.default.removeItem(at: root) }
        let buildDir = root.appendingPathComponent(
            "Build/Intermediates.noindex/ArchiveIntermediates/FuturaTerm/BuildProductsPath"
        )
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let found = try find(env: ["BUILD_DIR": buildDir.path, "SRCROOT": root.path])
        #expect(found == artifactPath(root: root))

        let oldGlob = buildDir
            .appendingPathComponent(
                "../../SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
            )
            .standardizedFileURL
        #expect(!FileManager.default.fileExists(atPath: oldGlob.path))
    }

    @Test
    func finds_sparkle_already_copied_into_the_configuration_build_dir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sparkle-embed-products-\(UUID().uuidString)", isDirectory: true)
        let products = root.appendingPathComponent("Release/Sparkle.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let found = try find(env: [
            "CONFIGURATION_BUILD_DIR": root.appendingPathComponent("Release").path,
            "SRCROOT": root.path,
        ])
        #expect(found == products.path)
    }

    @Test
    func direct_embed_copies_framework_into_the_app_bundle() throws {
        let root = try layout()
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("Build/Products/Release")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let contents = "FuturaTerm.app/Contents"
        let result = try run(
            env: [
                "BUILD_DIR": root.appendingPathComponent("Build/Products").path,
                "BUILT_PRODUCTS_DIR": products.path,
                "CONTENTS_FOLDER_PATH": contents,
                "CONFIGURATION": "Release",
                "SRCROOT": root.path,
            ]
        )
        #expect(result.status == 0, "stderr: \(result.stderr)")
        let marker = products
            .appendingPathComponent(contents)
            .appendingPathComponent("Frameworks/Sparkle.framework/marker.txt")
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func app_store_strips_framework_from_the_app_bundle() throws {
        let root = try layout()
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("Build/Products/AppStore")
        let contents = "FuturaTerm.app/Contents"
        let frameworks = products.appendingPathComponent("\(contents)/Frameworks/Sparkle.framework")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let executableDir = products.appendingPathComponent("\(contents)/MacOS")
        try FileManager.default.createDirectory(at: executableDir, withIntermediateDirectories: true)
        let executable = executableDir.appendingPathComponent("FuturaTerm")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: executable)

        let result = try run(
            env: [
                "BUILT_PRODUCTS_DIR": products.path,
                "CONTENTS_FOLDER_PATH": contents,
                "CONFIGURATION": "AppStore",
                "EXECUTABLE_PATH": "\(contents)/MacOS/FuturaTerm",
                "SRCROOT": repoFile("LICENSE").deletingLastPathComponent().path,
            ]
        )
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: frameworks.path))
    }

    @Test
    func find_fails_when_no_artifact_exists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sparkle-embed-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try run(
            args: ["--find"],
            env: [
                "BUILD_DIR": root.appendingPathComponent("Build/Products").path,
                "SRCROOT": root.path,
            ]
        )
        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }

    // MARK: - helpers

    private func artifactPath(root: URL) -> String {
        root.appendingPathComponent(
            "SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        ).path
    }

    private func layout() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sparkle-embed-\(UUID().uuidString)", isDirectory: true)
        let artifact = URL(fileURLWithPath: artifactPath(root: root), isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try "sparkle".write(
            to: artifact.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Build/Products"),
            withIntermediateDirectories: true
        )
        return root
    }

    private func find(env: [String: String]) throws -> String {
        let result = try run(args: ["--find"], env: env)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        return result.stdout
    }

    private func run(args: [String] = [], env extra: [String: String]) throws -> (
        status: Int32, stdout: String, stderr: String
    ) {
        let script = try repoFile("scripts/embed-sparkle.sh")
        var env = ProcessInfo.processInfo.environment
        for key in [
            "BUILD_DIR", "BUILT_PRODUCTS_DIR", "CONFIGURATION_BUILD_DIR",
            "OBJROOT", "SYMROOT", "SRCROOT", "CONFIGURATION",
            "CONTENTS_FOLDER_PATH", "EXECUTABLE_PATH",
        ] {
            env.removeValue(forKey: key)
        }
        for (key, value) in extra {
            env[key] = value
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + args
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func repoFile(_ relative: String) throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        while true {
            let candidate = dir.appendingPathComponent("LICENSE")
            if fm.fileExists(atPath: candidate.path) {
                return dir.appendingPathComponent(relative)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                throw TestError.missingRepoRoot
            }
            dir = parent
        }
    }

    private enum TestError: Error {
        case missingRepoRoot
    }
}
