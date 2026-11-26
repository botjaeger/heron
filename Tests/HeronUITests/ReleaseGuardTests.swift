import Foundation
import Testing

/// The release pipeline's rules (docs.md › Distribution), read from the scripts themselves.
@Suite struct ReleaseGuardTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ path: String) throws -> String { try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8) }

    /// A self-signed certificate has no Team ID, so with the hardened runtime dyld refuses Sparkle
    /// ("different Team IDs", 2026-11-26): Heron Signing builds go without it.
    @Test func heronSigningBuildsSkipTheHardenedRuntime() throws {
        let app = try read("packaging/make-app.sh")
        let line = try #require(app.split(separator: "\n").first { $0.contains("OPTS=(--force --sign \"$SIGN_ID\")") }, "make-app.sh signs without the runtime somewhere")
        #expect(line.contains("\"Heron Signing\""), "Heron Signing must take the no-runtime branch: \(line)")
    }

    /// The certificate and the Sparkle key stay in the Mac's keychain: the release reads them from
    /// there, checks the build carries the certificate, and nothing in the repo takes a key file.
    @Test func releasesAreSignedOnThisMacOnly() throws {
        let release = try read("scripts/release.sh")
        #expect(release.contains("IDENTITY=\"Heron Signing\""))
        #expect(release.contains("SIGN_ID=\"$IDENTITY\""))
        #expect(release.contains("certificate leaf"), "release.sh must refuse a build without the certificate")
        #expect(release.contains("sign_update\" --account heron"))
        #expect(release.contains("refs/tags/$TAG"))
        for path in ["scripts/release.sh", ".github/workflows/release.yml", ".github/workflows/pages.yml"] {
            let text = try read(path)
            #expect(!text.contains("--ed-key-file"), "\(path) passes the Sparkle key as a file")
            #expect(!text.contains("secrets."), "\(path) reads a secret: signing happens on the Mac")
        }
        let workflow = try read(".github/workflows/release.yml")
        #expect(!workflow.contains("gh release"), "the workflow is a build check; it publishes nothing")
    }

    /// The public key the release build embeds is the one in the repo, a 32-byte Ed25519 key.
    @Test func theSparklePublicKeyIsWellFormed() throws {
        let key = try read("packaging/sparkle-ed.pub").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Data(base64Encoded: key)?.count == 32, "\(key)")
        #expect(try read("scripts/release.sh").contains("ED_KEY=\"$(<packaging/sparkle-ed.pub)\""))
    }
}
