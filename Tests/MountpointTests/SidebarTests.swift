import Foundation
import Testing
@testable import Mountpoint

struct SidebarTests {
    /// Nur eigene Einträge (ohne Name/DateLastSeen) ausgeworfener Volumes mit unseren Namen werden gelöscht.
    @Test func staleOnlyOwnEjectedEntries() throws {
        // irgendein Volume, das es gibt (Lesezeichen brauchen ein existierendes Ziel); „ausgeworfen“ simuliert `exists`
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: "/Volumes").first { !$0.hasPrefix(".") })
        let bookmark = try URL(fileURLWithPath: "/Volumes/" + name).bookmarkData()
        let item: [String: Any] = ["Bookmark": bookmark, "uuid": "x", "visibility": 1]
        let gone: (String) -> Bool = { _ in false }
        #expect(Sidebar.isStale(item, names: [name], exists: gone))
        #expect(!Sidebar.isStale(item, names: [name], exists: { _ in true }))          // eingehängt
        #expect(!Sidebar.isStale(item, names: ["Other"], exists: gone))                  // fremder Name
        #expect(!Sidebar.isStale(item.merging(["Name": name]) { $1 }, names: [name], exists: gone))   // Eintrag des Finders
        #expect(!Sidebar.isStale(item.merging(["CustomItemProperties": ["com.apple.LSSharedFileList.DateLastSeen": Date()]]) { $1 },
                                 names: [name], exists: gone))
        #expect(!Sidebar.isStale(["uuid": "x"], names: [name], exists: gone))           // ohne Lesezeichen
    }

    /// Sicherungen folgen keinem Symlink: weder am Ordner (Ziel bleibt leer) noch an der Datei (der Link wird ersetzt,
    /// sein Ziel bleibt unberührt) – die Aufräum-App hat Festplattenvollzugriff.
    @Test func backupsNeverFollowSymlinks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mp-nofollow-\(UUID())")
        let real = dir.appendingPathComponent("real"), outside = dir.appendingPathComponent("outside")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let data = Data("backup".utf8)

        try Sidebar.writeNoFollow(data, to: real.appendingPathComponent("b.sfl3"))
        #expect(try Data(contentsOf: real.appendingPathComponent("b.sfl3")) == data)

        let linkDir = dir.appendingPathComponent("linkdir")
        try fm.createSymbolicLink(at: linkDir, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try Sidebar.writeNoFollow(data, to: linkDir.appendingPathComponent("b.sfl3")) }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)

        let victim = outside.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        try fm.createSymbolicLink(at: real.appendingPathComponent("c.sfl3"), withDestinationURL: victim)
        try Sidebar.writeNoFollow(data, to: real.appendingPathComponent("c.sfl3"))
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
        let c = real.appendingPathComponent("c.sfl3")
        #expect(try fm.attributesOfItem(atPath: c.path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: c) == data)
    }

    /// Kopie der Aufräum-App: angelegt, unverändert gelassen wenn gleich, ersetzt wenn anders, ein Link wird ersetzt statt gefolgt
    @Test func installCleanupCopy() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mp-install-\(UUID())")
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src/Mountpoint Cleanup.app"), target = dir.appendingPathComponent("dst/Mountpoint Cleanup.app")
        let exe = "Contents/MacOS/Mountpoint Cleanup"
        try fm.createDirectory(at: source.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: source.appendingPathComponent(exe))

        try Sidebar.installCleanup(from: source, to: target)
        #expect(try Data(contentsOf: target.appendingPathComponent(exe)) == Data("v1".utf8))
        let marker = target.appendingPathComponent("marker")
        try Data().write(to: marker)
        try Sidebar.installCleanup(from: source, to: target)            // gleich: nicht angefasst
        #expect(fm.fileExists(atPath: marker.path))
        try Data("v2".utf8).write(to: source.appendingPathComponent(exe))
        try Sidebar.installCleanup(from: source, to: target)            // anders: ersetzt
        #expect(try Data(contentsOf: target.appendingPathComponent(exe)) == Data("v2".utf8) && !fm.fileExists(atPath: marker.path))

        let elsewhere = dir.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.removeItem(at: target)
        try fm.createSymbolicLink(at: target, withDestinationURL: elsewhere)
        try Sidebar.installCleanup(from: source, to: target)
        #expect(try fm.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType == .typeDirectory)
        #expect(try fm.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["Mountpoint Cleanup.app"])   // kein Rest
    }

    /// Bereinigung an einer Kopie: Sicherung = alte Datei, nur der eigene Eintrag fehlt, alles andere bleibt, Neustart nur bei Änderung.
    @Test func purgeOnFixture() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mp-sfl-\(UUID())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let list = dir.appendingPathComponent("list.sfl3"), backup = dir.appendingPathComponent("backup.sfl3"), backupURL = backup
        let name = try #require(try fm.contentsOfDirectory(atPath: "/Volumes").first { !$0.hasPrefix(".") })
        let bookmark = try URL(fileURLWithPath: "/Volumes/" + name).bookmarkData()
        let own: [String: Any] = ["Bookmark": bookmark, "uuid": "own", "visibility": 1]
        let finders: [String: Any] = ["Bookmark": bookmark, "uuid": "finder", "Name": name, "visibility": 0]
        let root: [String: Any] = ["items": [own, finders], "properties": ["com.apple.LSSharedFileList.ForceTemplateIcons": false]]
        let original = try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
        try original.write(to: list)
        var restarts = 0
        func run(_ names: Set<String>, backup: URL? = nil) -> Int? {
            Sidebar.purge(names: names, list: list, backup: backup ?? backupURL, exists: { _ in false }, restart: { restarts += 1; return true })
        }

        #expect(run(["Other"]) == 0)                                     // nichts Eigenes: nichts schreiben
        #expect(restarts == 0 && !fm.fileExists(atPath: backup.path))
        #expect(run([name]) == 1)
        #expect(restarts == 1)
        #expect(try Data(contentsOf: backup) == original)                // Sicherung = alte Datei
        let u = try NSKeyedUnarchiver(forReadingFrom: Data(contentsOf: list)); u.requiresSecureCoding = false
        let after = try #require(u.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [String: Any])
        let items = try #require(after["items"] as? [[String: Any]])
        #expect(items.count == 1 && (items[0] as NSDictionary) == (finders as NSDictionary))   // Eintrag des Finders bleibt unverändert
        #expect((after["properties"] as? NSDictionary) == (root["properties"] as? NSDictionary))
        let first = backup.deletingPathExtension().appendingPathExtension("first.sfl3")
        #expect(try Data(contentsOf: first) == original)                 // erste Sicherung bleibt
        let second = try NSKeyedArchiver.archivedData(withRootObject: ["items": [own, finders, own], "properties": [:]] as [String: Any],
                                                      requiringSecureCoding: false)
        try second.write(to: list)                                       // zweite Bereinigung mit anderer Liste
        #expect(run([name]) == 2)
        #expect(try Data(contentsOf: first) == original)                 // erste Sicherung nie überschrieben
        #expect(try Data(contentsOf: backup) == second)                  // die letzte hält die zweite Liste
        restarts = 1

        try original.write(to: list)                                     // Neustart scheitert: trotzdem gezählt
        #expect(Sidebar.purge(names: [name], list: list, backup: backup, exists: { _ in false }, restart: { false }) == 1)
        try original.write(to: list)                                     // Sicherung nicht schreibbar: Liste bleibt
        let nowhere = dir.appendingPathComponent("fehlt/backup.sfl3")
        #expect(run([name], backup: nowhere) == nil)
        #expect(try Data(contentsOf: list) == original && restarts == 1)
        try NSKeyedArchiver.archivedData(withRootObject: ["properties": [:]] as [String: Any], requiringSecureCoding: false).write(to: list)
        #expect(run([name]) == nil && restarts == 1)                     // ohne items: nichts anfassen

        try Data("kaputt".utf8).write(to: list)                          // unlesbar: nichts anfassen
        #expect(run([name]) == nil)
        #expect(try Data(contentsOf: list) == Data("kaputt".utf8) && restarts == 1)
        try fm.removeItem(at: list)                                      // fehlt: nichts anfassen
        #expect(run([name]) == nil && restarts == 1)
    }

    /// Ein gültiges Archiv mit unbekannter Klasse (z. B. ein neues Format) darf die App nicht abstürzen lassen.
    @Test func purgeSurvivesUnknownClass() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-sfl-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = dir.appendingPathComponent("list.sfl3")
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("MPNoSuchClass", for: Opaque.self)
        archiver.encode(["items": [["x": Opaque()]]] as NSDictionary, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        try archiver.encodedData.write(to: list)
        var restarted = false
        #expect(Sidebar.purge(names: ["x"], list: list, backup: dir.appendingPathComponent("b.sfl3"),
                              restart: { restarted = true; return true }) == nil)
        #expect(!restarted)
    }

    /// Selbsttest-Prüfung, nur lesend: lesbar mit Markierungen des Finders → ok; ohne jede Markierung oder ohne Datei → Fehler.
    @Test func inspectList() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mp-sfl-\(UUID())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let list = dir.appendingPathComponent("list.sfl3")
        let name = try #require(try fm.contentsOfDirectory(atPath: "/Volumes").first { !$0.hasPrefix(".") })
        let bookmark = try URL(fileURLWithPath: "/Volumes/" + name).bookmarkData()
        let own: [String: Any] = ["Bookmark": bookmark, "uuid": "own"]
        let finders: [String: Any] = ["Bookmark": bookmark, "uuid": "finder", "Name": name]
        func write(_ items: [[String: Any]]) throws {
            try NSKeyedArchiver.archivedData(withRootObject: ["items": items, "properties": [:]] as [String: Any], requiringSecureCoding: false).write(to: list)
        }
        try write([own, finders])
        let before = try Data(contentsOf: list)
        guard case .success(let summary) = Sidebar.inspect(names: [], list: list) else { Issue.record("readable list failed"); return }
        #expect(summary == "2 entries readable, 1 from the Finder, 0 stale")
        #expect(try Data(contentsOf: list) == before)                    // nur lesend
        try write([own])
        guard case .failure = Sidebar.inspect(names: [], list: list) else { Issue.record("list without Finder markers passed"); return }
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: list.path)   // wie ohne Festplattenvollzugriff
        guard case .failure(let denied) = Sidebar.inspect(names: [], list: list) else { Issue.record("unreadable list passed"); return }
        #expect(denied.noAccess)
        try fm.removeItem(at: list)
        guard case .failure(let missing) = Sidebar.inspect(names: [], list: list) else { Issue.record("missing list passed"); return }
        #expect(!missing.noAccess)
    }

    @Test func temporaryPlace() {
        #expect(runsFromTemporaryPlace(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Mountpoint.app")))
        #expect(!runsFromTemporaryPlace(FileManager.default.temporaryDirectory))   // beschreibbar
    }
}

@objc(MPOpaqueTestObject) private final class Opaque: NSObject, NSCoding {
    override init() {}
    init?(coder: NSCoder) {}
    func encode(with coder: NSCoder) {}
}
