import Foundation
import Testing
@testable import Mountpoint

/// Fehler sollen sagen, was los ist und was man tun kann.
struct ErrorMessageTests {
    @Test func nasErrorsAreExplained() {
        #expect(Mounter.netfsMessage(EAUTH, host: "nas", share: "/A").contains("rejected the login"))
        #expect(Mounter.netfsMessage(EHOSTUNREACH, host: "nas", share: "/A").contains("cannot be reached"))
        #expect(Mounter.netfsMessage(ETIMEDOUT, host: "nas", share: "/A").contains("cannot be reached"))
        #expect(Mounter.netfsMessage(ENOENT, host: "nas", share: "/Archiv").contains("“/Archiv”"))
        #expect(Mounter.netfsMessage(-128, host: "nas", share: "/A").contains("cancelled"))
        #expect(Mounter.netfsMessage(12345, host: "nas", share: "/A").contains("12345"))
    }

    @Test func missingDriveOrFolder() {
        let none: (String) -> Bool = { _ in false }
        let all: (String) -> Bool = { _ in true }
        #expect(Mounter.missingFolderMessage("/Volumes/ARCHIV/2024/AI_Media", connected: none).contains("drive “ARCHIV” is not connected"))
        #expect(Mounter.missingFolderMessage("/Volumes/ARCHIV/2024/AI_Media", connected: all).contains("folder “AI_Media” no longer exists"))
        #expect(Mounter.missingFolderMessage("/Users/x/Media", connected: none).contains("folder “Media”"))
    }

    @Test func helperOutputIsTranslated() {
        #expect(Mounter.explainMountFailure("mount_macfuse: the file system is not available (1)", name: "A").contains("macFUSE could not be loaded"))
        #expect(Mounter.explainMountFailure("fuse: Permission denied", name: "A").contains("not allowed to read"))
        #expect(Mounter.explainMountFailure("source folder is inside the user's Library folder: refused", name: "A").contains("Library folder of your user account"))
        let other = Mounter.explainMountFailure("something odd", name: "A")
        #expect(other.contains("could not be mounted") && other.contains("Details: something odd"))
        #expect(!Mounter.explainMountFailure("", name: "A").contains("Details"))
    }

    @Test @MainActor func unreadableLibraryIsSetAsideNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-broken-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ kaputt".utf8).write(to: dir.appendingPathComponent("library.json"))
        let s = Store(directory: dir)
        #expect(s.library.workspaces.isEmpty)
        #expect(s.notice != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backup = try #require(files.first { $0.hasPrefix("library-unreadable-") })
        #expect(try String(contentsOf: dir.appendingPathComponent(backup), encoding: .utf8) == "{ kaputt")
    }

    @Test func unreadableFolderSaysWhy() {
        let (items, problem) = FolderBrowser.read(URL(fileURLWithPath: "/nicht/vorhanden"))
        #expect(items.isEmpty)
        #expect(problem != nil)
    }
}
