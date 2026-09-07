import Foundation

/// Install Moonlight.app into ~/Applications from the official GitHub DMG.
/// View Desktop needs the viewer on this Mac; the FuturaTerm .app drag-install
/// cannot ship it, so the first View Desktop fetches it.
enum MoonlightMacInstall {
    static let githubLatestRelease =
        URL(string: "https://api.github.com/repos/moonlight-stream/moonlight-qt/releases/latest")!

    static func applicationsMoonlightURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Moonlight.app", isDirectory: true)
    }

    static func systemMoonlightURL() -> URL {
        URL(fileURLWithPath: "/Applications/Moonlight.app", isDirectory: true)
    }

    static let binaryNames = ["moonlight-qt", "moonlight"]
    static let brewBinDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Homebrew cask/formula and PATH installs, including /opt/homebrew/bin.
    static func binaryURL(
        pathEnv: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        var dirs = pathEnv.split(separator: ":").map(String.init)
        for extra in brewBinDirectories where !dirs.contains(extra) {
            dirs.append(extra)
        }
        for dir in dirs {
            for name in binaryNames {
                let path = URL(fileURLWithPath: dir, isDirectory: true)
                    .appendingPathComponent(name).path
                if fileExists(path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    /// Prefer the official macOS disk image; skip Linux AppImages.
    static func diskImageDownloadURL(fromGitHubReleaseJSON data: Data) -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]]
        else { return nil }
        for asset in assets {
            guard let name = asset["name"] as? String else { continue }
            let lower = name.lowercased()
            guard lower.hasSuffix(".dmg"), lower.contains("moonlight"), !lower.contains("appimage")
            else { continue }
            if let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) {
                return url
            }
        }
        return nil
    }

    static func copyApp(fromVolume volume: URL, to destination: URL, fileManager: FileManager = .default)
        throws
    {
        let app = volume.appendingPathComponent("Moonlight.app", isDirectory: true)
        guard fileManager.fileExists(atPath: app.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: app, to: destination)
    }

    /// Download the latest official DMG, copy Moonlight.app into ~/Applications.
    static func installFromGitHub(
        home: String = NSHomeDirectory(),
        session: URLSession = .shared
    ) async -> URL? {
        let dest = applicationsMoonlightURL(home: home)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        do {
            var request = URLRequest(url: githubLatestRelease)
            request.setValue("FuturaTerm", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await session.data(for: request)
            guard let dmgURL = diskImageDownloadURL(fromGitHubReleaseJSON: data) else { return nil }
            let (tmp, _) = try await session.download(from: dmgURL)
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent("Moonlight-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: tmp, to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            guard let volume = attachDiskImage(local) else { return nil }
            defer { detachDiskImage(volume) }
            try copyApp(fromVolume: volume, to: dest)
            return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
        } catch {
            return nil
        }
    }

    static func attachDiskImage(_ dmg: URL) -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", "-nobrowse", "-readonly", dmg.path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let mount = text.split(whereSeparator: \.isNewline).last else { return nil }
        let path = String(mount.split(separator: "\t").last ?? mount.split(separator: " ").last ?? "")
        let url = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        let app = url.appendingPathComponent("Moonlight.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: app.path) ? url : nil
    }

    static func detachDiskImage(_ volume: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", volume.path, "-quiet"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }
}
