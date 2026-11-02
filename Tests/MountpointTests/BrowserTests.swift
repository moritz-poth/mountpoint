import Foundation
import Testing
@testable import Mountpoint

struct BrowserTests {
    @Test func listsFoldersOnlyAndMarksAvid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-browse-\(UUID())")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("b_Projekt/Avid MediaFiles"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("A_Leer"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".versteckt"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Paket.app"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("datei.txt"))
        defer { try? fm.removeItem(at: dir) }

        let items = FolderBrowser.list(dir)
        #expect(items.map(\.name) == ["A_Leer", "b_Projekt"])
        #expect(items.map(\.avid) == [false, true])
    }

    @Test func rootListsVolumes() {
        #expect(FolderBrowser.list(nil).contains { $0.url.path == "/" })
    }
}

struct CreateFolderTests {
    @Test func makeFolderWithAvid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-mk-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try makeFolder(named: "Doku_2026", in: dir, withAvid: true)
        #expect(FileManager.default.fileExists(atPath: url.path + "/Avid MediaFiles/MXF"))
        // vorhandener Ordner wird nie überschrieben
        try Data("x".utf8).write(to: url.appendingPathComponent("Avid MediaFiles/MXF/a.mxf"))
        #expect(throws: MountError.self) { try makeFolder(named: "Doku_2026", in: dir, withAvid: true) }
        try createAvidFolders(in: url)
        #expect(FileManager.default.fileExists(atPath: url.path + "/Avid MediaFiles/MXF/a.mxf"))

        let plain = try makeFolder(named: "Leer", in: dir, withAvid: false)
        #expect(!FileManager.default.fileExists(atPath: plain.path + "/Avid MediaFiles"))
        #expect(throws: MountError.self) { try makeFolder(named: "a/b", in: dir, withAvid: false) }
        #expect(throws: MountError.self) { try makeFolder(named: ".x", in: dir, withAvid: false) }
    }
}
