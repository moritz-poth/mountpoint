import Foundation
import Testing
@testable import Mountpoint

/// Eingabe → erwartete Ausgabe, pro Eingabeklasse eine Zeile (normal, leer, Grenze, Sonderzeichen, Unsinn).
struct IOTests {
    // MARK: Versionen (GitHub-Tags, eigene Version)

    @Test(arguments: [
        ("1.4.1", [1, 4, 1], nil as Int?),
        ("v1.4.1", [1, 4, 1], nil),
        ("  v2.0  ", [2, 0], nil),
        ("1", [1], nil),
        ("1.0.0-beta.3", [1, 0, 0], 3),
        ("1.0.0-BETA.12", [1, 0, 0], 12),
    ])
    func versionParses(_ text: String, _ numbers: [Int], _ beta: Int?) throws {
        let v = try #require(AppVersion(text))
        #expect(v.numbers == numbers)
        #expect(v.beta == beta)
    }

    @Test(arguments: ["", "v", "  ", "dev", "1.0.0-rc", "1.0.0-beta", "1.0.0-beta.x", "1.a.0", "1.0.0-beta.1-x", "-beta.1"])
    func versionRejects(_ text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test(arguments: [
        ("1.4.0", "1.4.1"), ("1.9.9", "1.10.0"), ("1.4", "1.4.1"), ("1.4.1-beta.9", "1.4.1"),
        ("1.4.1-beta.2", "1.4.1-beta.10"), ("1.4.1", "1.4.2-beta.1"), ("0.9", "1"),
    ])
    func versionOlder(_ old: String, _ new: String) {
        #expect(AppVersion(old)! < AppVersion(new)!)
        #expect(!(AppVersion(new)! < AppVersion(old)!))
    }

    // MARK: Pfade und Namen

    @Test(arguments: [
        ("/Volumes/A/b/c", "/Volumes/A", "b/c"),
        ("/Volumes/A/b", "/Volumes/A/", "b"),
        ("/Volumes/A", "/Volumes/A", ""),
        ("/Volumes/A/", "/Volumes/A", ""),
        ("/Volumes/AB/c", "/Volumes/A", "/Volumes/AB/c"),     // kein Präfix ohne Pfadgrenze
        ("/x", "/Volumes/A", "/x"),
        ("/a/b", "/", "a/b"),
    ])
    func relativePath(_ path: String, _ root: String, _ expected: String) {
        #expect(relative(path, to: root) == expected)
    }

    @Test(arguments: [
        ("smb://editor@NAS.local/Archiv", "smb://nas.local/archiv/", true),
        ("smb://nas/Archiv", "smb://nas/Archiv", true),
        ("smb://nas/Archiv", "smb://nas/Archiv2", false),
        ("smb://nas/Archiv", "afp://nas/Archiv", false),
        ("smb://nas/Archiv", "smb://nas2/Archiv", false),
        ("smb://nas/Archiv/Sub", "smb://nas/Archiv", false),
    ])
    func shares(_ a: String, _ b: String, _ same: Bool) {
        #expect(sameShare(URL(string: a)!, URL(string: b)!) == same)
    }

    @Test(arguments: [("", ""), ("plain", "plain"), ("A,B", "A\\,B"), ("C\\D", "C\\\\D"), ("a\\,b", "a\\\\\\,b"), ("Ä ö 🎬", "Ä ö 🎬")])
    func fuseEscaping(_ input: String, _ expected: String) {
        #expect(fuseEscape(input) == expected)
    }

    @Test(arguments: [
        ("Schnitt-1.1", "Schnitt-1", true),
        ("schnitt-1.1", "Schnitt-1", true),      // Groß/klein egal
        ("Schnitt-1.10", "Schnitt-1", false),
        ("Schnitt-1.2", "Schnitt-1", false),
        ("Schnitt-1.1 ", "Schnitt-1", false),
        ("1", "Schnitt-1", false),
        ("Schnitt-1", "Schnitt-1", false),
        (".1", "", false),                       // ohne Rechnernamen nie
    ])
    func ownFolder(_ name: String, _ computer: String, _ expected: Bool) {
        #expect(isOwnFolder(name, computer: computer) == expected)
    }

    @Test(arguments: [
        ("/", "/Users/Shared/AvidMediaComposer"),
        ("Media", "/Volumes/Media"),
        ("Media Disk", "/Volumes/Media Disk"),
        ("/Volumes/Filespace/Projekt", "/Volumes/Filespace/Projekt"),
    ])
    func guardRoots(_ entry: String, _ root: String) {
        #expect(guardRoot(entry) == root)
    }

    @Test(arguments: [
        ("/Volumes/Media", "Media"),
        ("/Volumes/Media Disk", "Media Disk"),
        ("/Volumes/Filespace/Projekt", "/Volumes/Filespace/Projekt"),   // LucidLink: voller Pfad
        ("/", "/"),                                                      // = systemGuard
    ])
    func guardEntries(_ mountPoint: String, _ entry: String) {
        #expect(guardEntry(mountPoint) == entry)
        if mountPoint != "/" { #expect(guardRoot(guardEntry(mountPoint)) == mountPoint) }   // hin und zurück
    }

    // MARK: Alarm-Pause

    @Test func snoozeEnds() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let at = { (d: Int, h: Int, m: Int) in cal.date(from: DateComponents(year: 2026, month: 3, day: d, hour: h, minute: m))! }
        #expect(snoozeEnd(.minutes(5), from: at(10, 12, 0), calendar: cal) == at(10, 12, 5))
        #expect(snoozeEnd(.minutes(240), from: at(10, 22, 0), calendar: cal) == at(11, 2, 0))
        #expect(snoozeEnd(.restOfDay, from: at(10, 23, 59), calendar: cal) == at(11, 0, 0))
        #expect(snoozeEnd(.restOfDay, from: at(10, 0, 0), calendar: cal) == at(11, 0, 0))
        // Zeitumstellung 29.3.2026: der Tag hat 23 Stunden, Ende trotzdem Mitternacht
        #expect(snoozeEnd(.restOfDay, from: at(29, 10, 0), calendar: cal) == at(30, 0, 0))
    }

    // MARK: Dateien zählen, Ordner anlegen

    @Test func fileCountClasses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("io-count-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        #expect(fileCount(dir.path) == 0)                                          // leer
        #expect(fileCount(dir.path + "/missing") == nil)                           // fehlt
        for f in ["a.mxf", "b.mxf", "msmMMOB.mdb", ".DS_Store", "._a.mxf"] { fm.createFile(atPath: dir.path + "/" + f, contents: Data()) }
        try fm.createDirectory(at: dir.appendingPathComponent("Creating"), withIntermediateDirectories: false)
        #expect(fileCount(dir.path) == 3)                                          // ohne versteckte, ohne Unterordner
        #expect(fileCount(dir.path + "/a.mxf") == nil)                             // Datei statt Ordner
    }

    @Test(arguments: [("Projekt", true), ("Mit Leerzeichen", true), ("Ümlaut 🎬", true), ("Doku: Teil 2", true)])
    func makeFolderAccepts(_ name: String, _ withAvid: Bool) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeFolder(named: name, in: dir, withAvid: withAvid)
        #expect(url.lastPathComponent == name)
        #expect(FileManager.default.fileExists(atPath: url.path + "/Avid MediaFiles/MXF"))
        #expect(throws: MountError.self) { try makeFolder(named: name, in: dir, withAvid: false) }   // gibt es schon
        let plain = try makeFolder(named: name + " ohne", in: dir, withAvid: false)
        #expect(!FileManager.default.fileExists(atPath: plain.path + "/Avid MediaFiles"))
    }

    @Test(arguments: ["a/b", "/", ".versteckt", ".", "..", "", String(repeating: "x", count: 256)])
    func makeFolderRefuses(_ name: String) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) { try makeFolder(named: name, in: dir, withAvid: true) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)   // nichts angelegt
    }

    // MARK: library.json

    @Test(arguments: [
        #"{}"#,
        #"{"projects":null,"workspaces":null}"#,
        #"{"projects":[],"workspaces":[],"future":42}"#,
        #"{"guarded":["Media","/"]}"#,
    ])
    func libraryLoadsOldAndNewFiles(_ json: String) throws {
        let lib = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        #expect(lib.projects.isEmpty && lib.workspaces.isEmpty)
        #expect(lib.guardOwn.isEmpty)
    }

    @Test(arguments: [#""#, #"[]"#, #"{"projects":"x"}"#, #"{"guarded":[1]}"#, #"{"projects":[{}]}"#])
    func libraryRejectsBroken(_ json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Library.self, from: Data(json.utf8)) }
    }

    // MARK: Seitenleiste

    @Test func staleNeedsReadableBookmark() {
        #expect(!Sidebar.isStale(["Bookmark": Data("kein Lesezeichen".utf8)], names: ["A"], exists: { _ in false }))
        #expect(!Sidebar.isStale(["Bookmark": "falscher Typ"], names: ["A"], exists: { _ in false }))
        #expect(!Sidebar.isStale([:], names: [], exists: { _ in false }))
    }

    // MARK: Anonymisieren (Berichte verlassen den Rechner)

    @Test func anonymizeRemovesPersonalNames() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = NSUserName()
        let cases = [
            "\(home)/Movies/Projekt X/clip.mxf",
            "/Users/\(user)/Desktop/Doku",
            "mount /Volumes/Archive Disk/Avid MediaFiles/MXF/1 failed",
            "smb://editor@nas.local/Archiv/2024 not reachable",
            "user \(user) on \(Host.current().localizedName ?? "x")",
        ]
        for text in cases {
            let out = anonymize(text)
            if user.count > 2 { #expect(!out.contains(user), "\(out)") }
            if let host = Host.current().localizedName, host.count > 2 { #expect(!out.contains(host), "\(out)") }
            for secret in ["Movies", "Projekt X", "Desktop", "Doku", "Archive Disk", "editor", "nas.local", "Archiv"] {
                #expect(!out.contains(secret), "\(secret) in \(out)")
            }
        }
    }

    @Test(arguments: [
        ("eject finished, 2 volumes", "eject finished, 2 volumes"),   // ohne Pfad unverändert
        ("", ""),
        ("/Volumes/MPSelftest-42/Avid MediaFiles/MXF/1", "/Volumes/MPSelftest-42/Avid MediaFiles/MXF/1"),   // Fachnamen bleiben
        ("/Users/Shared/AvidMediaComposer", "/Users/Shared/AvidMediaComposer"),
    ])
    func anonymizeKeeps(_ text: String, _ expected: String) {
        #expect(anonymize(text) == expected)
    }

    @Test func anonymizeIsStableAndDistinct() {
        let a = anonymize("/Volumes/Foo/x")
        #expect(a == anonymize("/Volumes/Foo/x"))                 // gleicher Name → gleiche Kennung
        #expect(a != anonymize("/Volumes/Bar/x"))                 // anderer Name → andere Kennung
        #expect(a.hasPrefix("/Volumes/n"))
        let arrow = anonymize("/Volumes/Foo → /Volumes/Bar")      // Pfeil trennt zwei Pfade
        #expect(arrow.contains(" → /Volumes/n") && !arrow.contains("Foo") && !arrow.contains("Bar"))
        #expect(anonymize("smb://a@nas/x").hasPrefix("smb://<server-"))
        #expect(anonymize("SMB://nas/x").hasPrefix("SMB://<server-"))
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
