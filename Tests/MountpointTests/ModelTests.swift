import Foundation
import Testing
@testable import Mountpoint

struct ModelTests {
    @Test func testRelative() {
        #expect(relative("/Volumes/Archiv/2024/Projekt", to: "/Volumes/Archiv") == "2024/Projekt")
        #expect(relative("/Volumes/Archiv/2024", to: "/Volumes/Archiv/") == "2024")
        #expect(relative("/Volumes/Archiv", to: "/Volumes/Archiv") == "")
        // Präfix ohne Pfadgrenze zählt nicht
        #expect(relative("/Volumes/Archiv2/x", to: "/Volumes/Archiv") == "/Volumes/Archiv2/x")
    }

    @Test func testSameShareIgnoresUserAndCase() {
        let a = URL(string: "smb://editor@NAS.local/Archiv")!
        #expect(sameShare(a, URL(string: "smb://nas.local/archiv/")!))
        #expect(!sameShare(a, URL(string: "smb://nas.local/Archiv2")!))
        #expect(!sameShare(a, URL(string: "afp://nas.local/Archiv")!))
    }

    @Test func testVolumeNameIsFolderName() {
        let w = Workspace(path: "/Volumes/Archive Disk/All In/MediaFiles/AI_Media")
        #expect(w.name == "AI_Media")
        #expect(w.volumePath == "/Volumes/AI_Media")
    }

    @Test func testFuseEscape() {
        #expect(fuseEscape("A,B") == "A\\,B")
        #expect(fuseEscape("C\\D") == "C\\\\D")
    }

    @Test func testLibraryRoundTrip() throws {
        let p = Project(name: "Doku", mountAtLaunch: true)
        let lib = Library(projects: [p], workspaces: [Workspace(path: "/x/y", project: p.id, share: "smb://nas/a", shareSubpath: "y")])
        let back = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(lib))
        #expect(back.projects == lib.projects)
        #expect(back.workspaces == lib.workspaces)
    }

    @Test func testLocalFolderHasNoShare() {
        let w = Workspace.make(url: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(w.share == nil)
    }
}
