import Foundation
import Testing
@testable import Mountpoint

/// Hängt wirklich ein. Nur mit `MOUNTPOINT_IT=1` und nach `scripts/build-app.sh` (braucht den Helfer).
struct MountTests {
    static let helper = ".build/helper/mirror"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUNTPOINT_IT"] == "1"))
    func mountWriteEject() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("MP Test,\(getpid())")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Avid MediaFiles/MXF/1"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: src) }
        let w = Workspace(path: src.path)

        try Mounter.mount(w, helper: Self.helper)
        #expect(Mounter.isMounted(w))
        // Standard: Netzlaufwerk (für Avid-Zusammenarbeit)
        #expect(try URL(fileURLWithPath: w.volumePath).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == false)
        let file = w.volumePath + "/Avid MediaFiles/MXF/1/a.mxf"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        #expect(FileManager.default.fileExists(atPath: src.path + "/Avid MediaFiles/MXF/1/a.mxf"))

        // Offene Datei: Auswerfen muss verweigert werden statt Gewalt
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        #expect(throws: MountError.self) { try Mounter.unmount(w) }
        try handle.close()

        // zweites Einhängen unter gleichem Namen ist harmlos
        try Mounter.mount(w, helper: Self.helper)
        // shortcut: macOS räumt den Mountpunkt nur weg, wenn das Volume schon registriert war (echter Betrieb: immer)
        Thread.sleep(forTimeInterval: 2)
        try Mounter.unmount(w)
        #expect(!Mounter.isMounted(w))
        #expect(gone(w.volumePath))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUNTPOINT_IT"] == "1"))
    func missingFolder() {
        #expect(throws: MountError.self) { try Mounter.mount(Workspace(path: "/nicht/da/X"), helper: Self.helper) }
    }
}

extension MountTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUNTPOINT_IT"] == "1"))
    func localMountWhenNetworkIsOff() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("MPLocal\(getpid())")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: src) }
        let w = Workspace(path: src.path)
        try Mounter.mount(w, helper: Self.helper, network: false)
        #expect(try URL(fileURLWithPath: w.volumePath).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true)
        Thread.sleep(forTimeInterval: 2)
        try Mounter.unmount(w)
    }

    /// Ein leerer Restordner in /Volumes (gehört root, die App kann ihn nicht löschen) darf das Einhängen nicht blockieren.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUNTPOINT_IT"] == "1"))
    func leftoverFolder() throws {
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: "/Volumes")).filter { $0.hasPrefix("MP Test,") }
        for name in leftovers {
            let w = Workspace(path: FileManager.default.temporaryDirectory.appendingPathComponent(name).path)
            try FileManager.default.createDirectory(atPath: w.path, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: w.path) }
            try Mounter.mount(w, helper: Self.helper)
            #expect(Mounter.isMounted(w))
            try Mounter.unmount(w)
        }
    }

    /// Ordner in ~/Library hängt der Helfer nie ein – auch nicht über einen Link dorthin (library.json schreibt jeder)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUNTPOINT_IT"] == "1"))
    func libraryFolderIsRefused() throws {
        let fm = FileManager.default
        let lib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MPLibTest\(getpid())").path
        let link = fm.temporaryDirectory.appendingPathComponent("MPLibLink\(getpid())").path
        try fm.createDirectory(atPath: lib, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: lib)
        defer { try? fm.removeItem(atPath: lib); try? fm.removeItem(atPath: link) }
        for path in [lib, link] {
            let w = Workspace(path: path)
            #expect { try Mounter.mount(w, helper: Self.helper) } throws: { ($0 as? MountError)?.message.contains("Library folder") == true }
            #expect(!Mounter.isMounted(w))
            try? Mounter.unmount(w)
        }
    }

    /// Ein Ordner, der am Volume vorbei gegen eine Verknüpfung getauscht wird, führt nicht aus dem Quellordner
    /// (der Helfer erbt Mountpoints Freigaben). chown auf der Volume-Wurzel geht weiter (chgrp, rsync -a).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUNTPOINT_IT"] == "1"))
    func swappedFolderNeverLeavesSource() throws {
        let fm = FileManager.default
        let src = fm.temporaryDirectory.appendingPathComponent("MPSwap\(getpid())").path
        let outside = fm.temporaryDirectory.appendingPathComponent("MPSwapOut\(getpid())").path
        defer { try? fm.removeItem(atPath: src); try? fm.removeItem(atPath: outside) }
        try fm.createDirectory(atPath: src + "/d/Messages", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outside + "/Messages", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: src + "/d/Messages/chat.db"))
        try Data("SECRET".utf8).write(to: URL(fileURLWithPath: outside + "/Messages/chat.db"))
        #expect(setxattr(outside + "/Messages/chat.db", "user.secret", "1", 1, 0, 0) == 0)
        let w = Workspace(path: src)
        try Mounter.mount(w, helper: Self.helper)
        defer { Thread.sleep(forTimeInterval: 2); try? Mounter.unmount(w) }

        #expect(chown(w.volumePath, getuid(), getgid()) == 0)
        let dir = open(w.volumePath + "/d", O_RDONLY | O_DIRECTORY), file = open(w.volumePath + "/d/Messages/chat.db", O_RDONLY)
        defer { close(dir); close(file) }
        #expect(dir >= 0 && file >= 0)
        // libfuse kennt "d" danach weiter als Ordner
        try fm.moveItem(atPath: src + "/d", toPath: src + "/d2")
        try fm.createSymbolicLink(atPath: src + "/d", withDestinationPath: outside)

        let escaped = openat(dir, "Messages/chat.db", O_RDONLY)
        #expect(escaped == -1)
        if escaped >= 0 { close(escaped) }   // sonst bliebe das Volume nach einem Fehlschlag eingehängt
        if #available(macOS 15, *) {   // darunter folgen xattrs einem getauschten Ordner noch (shortcut in mirror.c)
            #expect(fgetxattr(file, "user.secret", nil, 0, 0, 0) == -1)
            #expect(fsetxattr(file, "user.planted", "1", 1, 0, 0) == -1)
        }
        #expect(mkdirat(dir, "Messages/new", 0o755) == -1)
        #expect(unlinkat(dir, "Messages/chat.db", 0) == -1)
        if #available(macOS 15, *) { #expect(getxattr(outside + "/Messages/chat.db", "user.planted", nil, 0, 0, 0) == -1) }
        #expect(fm.fileExists(atPath: outside + "/Messages/chat.db"))
        #expect(!fm.fileExists(atPath: outside + "/Messages/new"))
    }
}

/// macOS entfernt den leeren Mountpunkt erst kurz nach dem Auswerfen.
func gone(_ path: String) -> Bool {
    for _ in 0..<50 where FileManager.default.fileExists(atPath: path) { Thread.sleep(forTimeInterval: 0.1) }
    return !FileManager.default.fileExists(atPath: path)
}
