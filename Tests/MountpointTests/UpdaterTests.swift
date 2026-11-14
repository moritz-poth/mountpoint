import CryptoKit
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
        // ohne Signatur wird nichts angeboten
        #expect(newestRelease(fromJSON: Data(json.utf8)) == nil)
        let r = newestRelease(fromJSON: Data(json.utf8), requireSignature: false)
        #expect(r?.tag == "v1.0.0-beta.10")
        #expect(r?.zip.absoluteString == "https://x/10.zip")
        let signed = json.replacingOccurrences(of: #"{"name":"Mountpoint-1.0.0-beta.7.zip","browser_download_url":"https://x/7.zip"}"#,
            with: #"{"name":"Mountpoint-1.0.0-beta.7.zip","browser_download_url":"https://x/7.zip"},{"name":"Mountpoint-1.0.0-beta.7.zip.sig","browser_download_url":"https://x/7.sig"}"#)
        #expect(newestRelease(fromJSON: Data(signed.utf8))?.signature?.absoluteString == "https://x/7.sig")
        // Schlüssel verloren: Markierung „.manual“ → Hinweis zum Selbstinstallieren, nie automatisch
        let manual = json.replacingOccurrences(of: #"{"name":"Mountpoint-1.0.0-beta.10.zip","browser_download_url":"https://x/10.zip"}"#,
            with: #"{"name":"Mountpoint-1.0.0-beta.10.zip","browser_download_url":"https://x/10.zip"},{"name":"Mountpoint-1.0.0-beta.10.manual","browser_download_url":"https://x/10.manual"}"#)
        let m = newestRelease(fromJSON: Data(manual.utf8))
        #expect(m?.tag == "v1.0.0-beta.10" && m?.manual == true && m?.signature == nil)
        // nur Links auf dieses Projekt werden geöffnet
        #expect(m?.safePage == Release.releasesPage)
        let own = Release(tag: "v1", page: URL(string: "https://github.com/moritz-poth/mountpoint/releases/tag/v1")!, zip: Release.releasesPage, signature: nil, manual: true)
        #expect(own.safePage == own.page)
        let evil = Release(tag: "v1", page: URL(string: "https://github.com/moritz-poth/mountpoint/releases.evil.com/x")!, zip: Release.releasesPage, signature: nil, manual: true)
        #expect(evil.safePage == Release.releasesPage)
        #expect(newestRelease(fromJSON: Data("{\"message\":\"rate limit\"}".utf8)) == nil)
    }

    /// Uses the zip from scripts/build-app.sh, if there is one.
    @Test func unpackAcceptsOnlyTheExpectedIntactApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dist = root.appendingPathComponent("dist")
        // das Zip der Version, die build-app.sh gerade baut – nicht irgendein altes
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        guard let release = script.split(separator: "\n").first(where: { $0.hasPrefix("RELEASE=") })?
                .dropFirst("RELEASE=".count).split(separator: " ").first.map(String.init) else { Issue.record("no RELEASE in build-app.sh"); return }
        let zipName = "Mountpoint-\(release).zip"
        guard FileManager.default.fileExists(atPath: dist.appendingPathComponent(zipName).path) else {
            // vor einem Release (MOUNTPOINT_RELEASE=1) muss der Build da sein, sonst wäre der Test still „grün“
            if ProcessInfo.processInfo.environment["MOUNTPOINT_RELEASE"] == "1" { Issue.record("\(zipName) missing – run scripts/build-app.sh first") }
            return
        }
        let zip = dist.appendingPathComponent(zipName)
        let tag = "v" + zipName.dropFirst("Mountpoint-".count).dropLast(".zip".count)
        let id = "io.github.moritz-poth.mountpoint"
        // eigener Testschlüssel statt des echten (der liegt nur im Schlüsselbund des Release-Macs)
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        func sign(_ url: URL) throws -> Data { Data(try key.signature(for: Data(contentsOf: url)).base64EncodedString().utf8) }
        let sig = try sign(zip)
        func unpack(_ z: URL, _ t: String, _ s: Data?, _ b: String = id, _ k: String = pub) throws -> URL {
            try Updater.unpack(z, expecting: t, signature: s, publicKey: k, bundleID: b)
        }
        let app = try unpack(zip, tag, sig)
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/mirror").path))
        // eingebettete Einstellungs-App: eigene Kennung, gleiche Version
        let nested = app.appendingPathComponent("Contents/Helpers/Mountpoint Settings.app/Contents")
        let info = NSDictionary(contentsOf: nested.appendingPathComponent("Info.plist"))
        #expect(info?["CFBundleIdentifier"] as? String == id + ".settings")
        #expect(info?["MountpointRelease"] as? String == release)
        #expect(FileManager.default.isExecutableFile(atPath: nested.appendingPathComponent("MacOS/Mountpoint Settings").path))
        #expect(throws: MountError.self) { try unpack(zip, "v9.9.9", sig) }
        #expect(throws: MountError.self) { try unpack(zip, tag, sig, "other.app") }
        // unsigned, signed by someone else, or signature of another file: refused
        #expect(throws: MountError.self) { try unpack(zip, tag, nil) }
        #expect(throws: MountError.self) { try unpack(zip, tag, sig, id, Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()) }
        // tampered: a changed file breaks the code signature (even if the zip itself were signed)
        let bad = try unpack(zip, tag, sig)
        try Data("x".utf8).write(to: bad.appendingPathComponent("Contents/Resources/LICENSE.txt"))
        let tampered = bad.deletingLastPathComponent().appendingPathComponent("t.zip")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", bad.path, tampered.path]; try p.run(); p.waitUntilExit()
        #expect(throws: MountError.self) { try unpack(tampered, tag, try sign(tampered)) }
        #expect(throws: MountError.self) { try unpack(tampered, tag, sig) }
        // eine veränderte Datei in der eingebetteten App bricht die Signatur ebenso
        let bad2 = try unpack(zip, tag, sig)
        try Data("x".utf8).write(to: bad2.appendingPathComponent("Contents/Helpers/Mountpoint Settings.app/Contents/Resources/de.lproj/InfoPlist.strings"))
        let tampered2 = bad2.deletingLastPathComponent().appendingPathComponent("t2.zip")
        let p2 = Process(); p2.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p2.arguments = ["-c", "-k", "--keepParent", bad2.path, tampered2.path]; try p2.run(); p2.waitUntilExit()
        #expect(throws: MountError.self) { try unpack(tampered2, tag, try sign(tampered2)) }
    }

    /// The zip from build-app.sh is signed with the key the app trusts (if build-app.sh could sign it).
    @Test func builtZipMatchesTheAppsKey() throws {
        let dist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist")
        guard let sigName = try? FileManager.default.contentsOfDirectory(atPath: dist.path).first(where: { $0.hasSuffix(".zip.sig") }) else { return }
        let zip = try Data(contentsOf: dist.appendingPathComponent(String(sigName.dropLast(4))))
        let sig = try Data(contentsOf: dist.appendingPathComponent(sigName))
        #expect(Updater.signatureValid(zip, sig))
        #expect(!Updater.signatureValid(zip + Data([0]), sig))
    }

    @Test func liveGitHubHasAParsableRelease() async throws {
        guard ProcessInfo.processInfo.environment["MOUNTPOINT_IT"] == "1" else { return }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/moritz-poth/mountpoint/releases?per_page=20")!)
        let r = try #require(newestRelease(fromJSON: data, requireSignature: false))
        #expect(AppVersion(r.tag)! >= AppVersion("v1.0.0-beta.7")!)
    }
}
