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
}

/// macOS entfernt den leeren Mountpunkt erst kurz nach dem Auswerfen.
func gone(_ path: String) -> Bool {
    for _ in 0..<50 where FileManager.default.fileExists(atPath: path) { Thread.sleep(forTimeInterval: 0.1) }
    return !FileManager.default.fileExists(atPath: path)
}
