import Foundation
import Testing

/// The public snapshot publisher is the only thing that keeps `website/` and
/// notarizing workflows off teton-web/futuraterm-oss. Drive the shipped script
/// (not a copied exclude list) so a dropped `rm` fails this test.
@MainActor
struct PublicSnapshotPublisherTests {
    @Test
    func publisher_strips_website_and_notarizing_workflows() throws {
        let url = repoRoot().appendingPathComponent("scripts/publish-public-snapshot.sh")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(source.contains("rm -rf website"))
        #expect(source.contains("rm -f .github/workflows/release.yml"))
        #expect(source.contains("rm -f .github/workflows/mas.yml"))
        #expect(source.contains("rm -f .github/workflows/website.yml"))
        #expect(source.contains("grep -qx '.github/workflows/website.yml'"))
        #expect(source.contains("package-ecosystem: bun"))
        #expect(source.contains("grep -q '^website/'"))
        #expect(source.contains("PRIVATE_REPO=\"teton-web/futuraterm\""))
        #expect(source.contains("PUBLIC_REPO=\"teton-web/futuraterm-oss\""))
        #expect(source.contains("github_nwo()"))
        // Prefix match would treat the OSS remote as the private repo.
        #expect(!source.contains("grep -F 'teton-web/futuraterm'"))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
