import Foundation
import Testing
@testable import Mountpoint

struct UpdaterTests {
    @Test func versionOrder() {
        let v = { AppVersion($0)! }
        #expect(v("v1.0.0-beta.7") < v("v1.0.0-beta.10"))
        #expect(v("1.0.0-beta.7") < v("1.0.0"))
        #expect(v("1.0.0") < v("1.0.1-beta.1"))
        #expect(v("1.0") == v("1.0.0"))
        #expect(!(v("1.0.0-beta.7") < v("v1.0.0-beta.7")))
        #expect(AppVersion("dev") == nil)
        #expect(AppVersion("1.0.0-rc") == nil)
    }

    @Test func newestReleaseSkipsDraftsAndReleasesWithoutZip() {
        let json = """
        [{"tag_name":"v1.0.0-beta.9","html_url":"https://x/9","draft":true,"assets":[{"name":"Mountpoint-1.0.0-beta.9.zip","browser_download_url":"https://x/9.zip"}]},
         {"tag_name":"v1.0.0-beta.8","html_url":"https://x/8","draft":false,"assets":[]},
         {"tag_name":"v1.0.0-beta.10","html_url":"https://x/10","draft":false,"assets":[{"name":"Mountpoint-1.0.0-beta.10.zip","browser_download_url":"https://x/10.zip"}]},
         {"tag_name":"v1.0.0-beta.7","html_url":"https://x/7","draft":false,"assets":[{"name":"Mountpoint-1.0.0-beta.7.zip","browser_download_url":"https://x/7.zip"}]}]
        """
        let r = newestRelease(fromJSON: Data(json.utf8))
        #expect(r?.tag == "v1.0.0-beta.10")
        #expect(r?.zip.absoluteString == "https://x/10.zip")
        #expect(newestRelease(fromJSON: Data("{\"message\":\"rate limit\"}".utf8)) == nil)
    }

    /// Uses the zip from scripts/build-app.sh, if there is one.
    @Test func unpackAcceptsOnlyTheExpectedIntactApp() throws {
        let dist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist")
        guard let zipName = try? FileManager.default.contentsOfDirectory(atPath: dist.path).first(where: { $0.hasSuffix(".zip") }) else { return }
        let zip = dist.appendingPathComponent(zipName)
        let tag = "v" + zipName.dropFirst("Mountpoint-".count).dropLast(".zip".count)
        let id = "io.github.moritz-poth.mountpoint"
        let app = try Updater.unpack(zip, expecting: tag, bundleID: id)
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/mirror").path))
        #expect(throws: Updater.UpdateError.self) { try Updater.unpack(zip, expecting: "v9.9.9", bundleID: id) }
        #expect(throws: Updater.UpdateError.self) { try Updater.unpack(zip, expecting: tag, bundleID: "other.app") }
        // tampered: a changed file breaks the signature
        let bad = try Updater.unpack(zip, expecting: tag, bundleID: id)
        try Data("x".utf8).write(to: bad.appendingPathComponent("Contents/Resources/LICENSE.txt"))
        let tampered = bad.deletingLastPathComponent().appendingPathComponent("t.zip")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", bad.path, tampered.path]; try p.run(); p.waitUntilExit()
        #expect(throws: Updater.UpdateError.self) { try Updater.unpack(tampered, expecting: tag, bundleID: id) }
    }

    @Test func liveGitHubHasAParsableRelease() async throws {
        guard ProcessInfo.processInfo.environment["MOUNTPOINT_IT"] == "1" else { return }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/moritz-poth/mountpoint/releases?per_page=20")!)
        let r = try #require(newestRelease(fromJSON: data))
        #expect(AppVersion(r.tag)! >= AppVersion("v1.0.0-beta.7")!)
    }
}
