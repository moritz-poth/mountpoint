import Foundation
import Testing
@testable import Mountpoint

struct SelfTestTests {
    @Test func anonymizeReplacesPersonalNamesButKeepsStructure() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let line = "mounted: /Volumes/BACKUPS/Kunde Geheim/AI_Media → /Volumes/AI_Media, log \(home)/Library/Logs/Mountpoint/Mountpoint.log, user \(NSUserName())"
        let a = anonymize(line)
        #expect(!a.contains("BACKUPS") && !a.contains("Kunde Geheim") && !a.contains("AI_Media"))
        #expect(!a.contains(home) && !a.contains(NSUserName()))
        #expect(a.contains("/Volumes/n") && a.contains("~/Library/Logs/Mountpoint/Mountpoint.log"))
        #expect(anonymize("/Volumes/MPSelftest-Net/Avid MediaFiles/MXF/1") == "/Volumes/MPSelftest-Net/Avid MediaFiles/MXF/1")
        // gleicher Name → gleiche Kennung (Zusammenhänge im Log bleiben erkennbar)
        #expect(anonymize("/Volumes/Archive") == anonymize("/Volumes/Archive"))
        let share = anonymize("workspace added: /Volumes/BACKUPS/x (share smb://Moe@DISKSTATION._smb._tcp.local/BACKUPS)")
        #expect(!share.contains("Moe") && !share.contains("DISKSTATION") && !share.contains("BACKUPS") && share.contains("smb://<server-"))
    }

    @Test func prereleasesOnlyWhenWanted() {
        let json = """
        [{"tag_name":"v1.1.0-beta.1","html_url":"https://github.com/moritz-poth/mountpoint/releases/tag/v1.1.0-beta.1","draft":false,"prerelease":true,
          "assets":[{"name":"Mountpoint-1.1.0-beta.1.zip","browser_download_url":"https://x/b.zip"},{"name":"Mountpoint-1.1.0-beta.1.zip.sig","browser_download_url":"https://x/b.sig"}]},
         {"tag_name":"v1.0.1","html_url":"https://github.com/moritz-poth/mountpoint/releases/tag/v1.0.1","draft":false,"prerelease":false,
          "assets":[{"name":"Mountpoint-1.0.1.zip","browser_download_url":"https://x/a.zip"},{"name":"Mountpoint-1.0.1.zip.sig","browser_download_url":"https://x/a.sig"}]}]
        """.data(using: .utf8)!
        #expect(newestRelease(fromJSON: json)?.tag == "v1.0.1")
        #expect(newestRelease(fromJSON: json, includePrereleases: true)?.tag == "v1.1.0-beta.1")
    }
}
