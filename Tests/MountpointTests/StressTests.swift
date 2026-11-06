import CryptoKit
import Foundation
import Testing
@testable import Mountpoint

/// Stresstest: hängt echte Volumes ein und belastet Helfer, Store und Wächter.
/// Nur mit `MOUNTPOINT_STRESS=1` und nach `scripts/build-app.sh`; alles in temporären Ordnern.
/// `swift test --filter Stress` – Messwerte erscheinen als „STRESS …“-Zeilen in der Ausgabe.
/// Auf einem anderen Laufwerk (NAS, LucidLink): `MOUNTPOINT_STRESS_ROOT=<Ordner>` – dort entsteht ein Testordner, der danach
/// wieder gelöscht wird. `MOUNTPOINT_STRESS_MB=<MB>` begrenzt die Datenmenge (Standard 512; Cloud-Laufwerke laden alles hoch).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOUNTPOINT_STRESS"] == "1"))
@MainActor
struct StressTests {
    let fm = FileManager.default
    let root = ProcessInfo.processInfo.environment["MOUNTPOINT_STRESS_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    let megabytes = Int(ProcessInfo.processInfo.environment["MOUNTPOINT_STRESS_MB"] ?? "") ?? 512

    // MARK: Hilfen

    func source(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("stress-\(getpid())-\(UUID().uuidString.prefix(4))").appendingPathComponent(name)
        try fm.createDirectory(at: url.appendingPathComponent("Avid MediaFiles/MXF"), withIntermediateDirectories: true)
        return url
    }

    func cleanup(_ src: URL) {
        // rm kommt mit Pfaden über PATH_MAX zurecht, FileManager nicht
        _ = try? Mounter.run("/bin/rm", ["-rf", src.deletingLastPathComponent().path])
    }

    func mounted(_ src: URL, network: Bool = true) throws -> Workspace {
        let w = Workspace(path: src.path)
        try Mounter.mount(w, helper: MountTests.helper, network: network)
        return w
    }

    /// Auswerfen; macOS braucht einen Moment, bis ein frisches Volume registriert ist.
    func eject(_ w: Workspace) {
        for _ in 0..<20 {
            if (try? Mounter.unmount(w)) != nil, !Mounter.isMounted(w) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        Issue.record("could not eject \(w.volumePath)")
    }

    func helperPID(_ src: URL) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "mirror \(src.path) "]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n").first.flatMap { pid_t($0) }
    }

    func seconds(_ block: () throws -> Void) rethrows -> Double {
        let t = Date()
        try block()
        return Date().timeIntervalSince(t)
    }

    func report(_ line: String) { print("STRESS \(line)") }

    nonisolated func random(_ count: Int) -> Data {
        var d = Data(count: count)
        d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return d
    }

    // MARK: Daten

    /// Viele Dateien parallel schreiben, über das Volume und direkt lesen, Prüfsummen vergleichen.
    @Test func parallelWritesStayIntact() throws {
        let src = try source("Stress IO")
        defer { cleanup(src) }
        let w = try mounted(src)
        defer { eject(w) }
        let n = 64
        let maxSize = max(1, megabytes * 2 / n) << 20   // im Mittel die Hälfte: insgesamt etwa `megabytes`
        var sums = [String](repeating: "", count: n)
        let lock = NSLock()
        let t = try seconds {
            var failures = 0
            DispatchQueue.concurrentPerform(iterations: n) { i in
                let size = Int.random(in: 1...maxSize)
                let data = random(size)
                do {
                    try data.write(to: URL(fileURLWithPath: w.volumePath + "/Avid MediaFiles/MXF/f\(i).mxf"))
                    lock.withLock { sums[i] = SHA256.hash(data: data).description }
                } catch { lock.withLock { failures += 1 } }
            }
            #expect(failures == 0)
            for i in 0..<n {
                let viaVolume = try Data(contentsOf: URL(fileURLWithPath: w.volumePath + "/Avid MediaFiles/MXF/f\(i).mxf"))
                let direct = try Data(contentsOf: src.appendingPathComponent("Avid MediaFiles/MXF/f\(i).mxf"))
                #expect(SHA256.hash(data: viaVolume).description == sums[i])
                #expect(SHA256.hash(data: direct).description == sums[i])
            }
        }
        report(String(format: "parallel writes: %d files in %.1f s", n, t))
    }

    /// Durchsatz einer großen Datei (wie eine MXF bei der Wiedergabe) – Volume gegen direkten Zugriff.
    @Test func largeFileThroughput() throws {
        let src = try source("Stress Big")
        defer { cleanup(src) }
        let w = try mounted(src)
        defer { eject(w) }
        let chunk = random(8 << 20)
        let chunks = max(1, megabytes / 8)
        func writeRead(_ path: String) throws -> (Double, Double) {
            let url = URL(fileURLWithPath: path)
            fm.createFile(atPath: path, contents: nil)
            let wt = try seconds {
                let h = try FileHandle(forWritingTo: url)
                for _ in 0..<chunks { try h.write(contentsOf: chunk) }
                try h.synchronize()
                try h.close()
            }
            let rt = try seconds {
                let h = try FileHandle(forReadingFrom: url)
                // F_NOCACHE: wirklich vom Datenträger lesen, nicht aus dem Cache
                _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
                while let d = try h.read(upToCount: 8 << 20), !d.isEmpty {}
                try h.close()
            }
            let mb = Double(chunks * 8)
            return (mb / wt, mb / rt)
        }
        let direct = try writeRead(src.path + "/direct.bin")
        let volume = try writeRead(w.volumePath + "/volume.bin")
        report(String(format: "%d MB direct: write %.0f MB/s, read %.0f MB/s", chunks * 8, direct.0, direct.1))
        report(String(format: "%d MB volume: write %.0f MB/s, read %.0f MB/s", chunks * 8, volume.0, volume.1))
        #expect(volume.1 > direct.1 * 0.2, "reading through the volume is more than 5× slower")
    }

    /// Tausende Dateien anlegen, umbenennen, auflisten, löschen.
    @Test func metadataStorm() throws {
        let src = try source("Stress Meta")
        defer { cleanup(src) }
        let w = try mounted(src)
        defer { eject(w) }
        func storm(_ root: String) throws -> Double {
            try seconds {
                for d in 0..<20 {
                    let dir = root + "/d\(d)"
                    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    for f in 0..<250 { fm.createFile(atPath: dir + "/f\(f).txt", contents: Data("\(f)".utf8)) }
                    for f in 0..<250 { try fm.moveItem(atPath: dir + "/f\(f).txt", toPath: dir + "/g\(f).txt") }
                    #expect(try fm.contentsOfDirectory(atPath: dir).count == 250)
                }
                try fm.removeItem(atPath: root + "/d0")
            }
        }
        let direct = try storm(src.path + "/meta")
        let volume = try storm(w.volumePath + "/meta2")
        report(String(format: "5000 files create/rename/list: direct %.1f s, volume %.1f s", direct, volume))
        #expect(try fm.contentsOfDirectory(atPath: src.path + "/meta2").count == 19)
    }

    /// Ungewöhnliche Namen: Komma, Backslash, Umlaut zerlegt (NFD), Emoji – im Volume-Namen und in Dateien.
    @Test func unusualNames() throws {
        // Backslash (für die Maskierung der Mount-Optionen) nur lokal: LucidLink lehnt ihn in Namen ab
        let name = root == fm.temporaryDirectory ? "Stress ,ü\\x 🎬" : "Stress ,ü x 🎬"
        let src = try source(name)
        defer { cleanup(src) }
        let w = try mounted(src)
        defer { eject(w) }
        #expect(try URL(fileURLWithPath: w.volumePath).resourceValues(forKeys: [.volumeNameKey]).volumeName == name)
        // „:“ erlaubt SMB (NAS, LucidLink) selbst nicht – das prüft nur der lokale Lauf
        let names = ["Cafe\u{301}.mxf", "Café.mxf", "🎬 Take 1.mxf", String(repeating: "x", count: 255)] + (root == fm.temporaryDirectory ? ["a:b.mxf"] : [])
        for n in names { fm.createFile(atPath: w.volumePath + "/" + n, contents: Data("1".utf8)) }
        let listed = Set(try fm.contentsOfDirectory(atPath: src.path))
        for n in names { #expect(listed.contains { $0.precomposedStringWithCanonicalMapping == n.precomposedStringWithCanonicalMapping }, "\(n)") }
    }

    /// Große erweiterte Attribute (Resource Forks alter Avid-/Finder-Dateien).
    @Test func bigExtendedAttributes() throws {
        let src = try source("Stress Xattr")
        defer { cleanup(src) }
        let w = try mounted(src)
        defer { eject(w) }
        let file = w.volumePath + "/fork.bin"
        fm.createFile(atPath: file, contents: Data("x".utf8))
        let fork = random(1 << 20)
        let set = fork.withUnsafeBytes { setxattr(file, "com.apple.ResourceFork", $0.baseAddress, fork.count, 0, 0) }
        #expect(set == 0, "setxattr: \(String(cString: strerror(errno)))")
        var back = Data(count: fork.count)
        let n = back.withUnsafeMutableBytes { getxattr(src.path + "/fork.bin", "com.apple.ResourceFork", $0.baseAddress, fork.count, 0, 0) }
        #expect(n == fork.count && back == fork)
    }

    /// Pfade länger als PATH_MAX im Quellordner: der Helfer muss ablehnen, nie einen gekürzten Pfad anlegen.
    @Test func overlongPathsNeverTruncate() throws {
        let src = try source("Stress Long")
        defer { cleanup(src) }
        let w = try mounted(src)
        defer { eject(w) }
        let comp = String(repeating: "a", count: 200)
        var fd = open(w.volumePath, O_RDONLY)
        var depth = 0
        while fd >= 0, depth < 12 {
            guard mkdirat(fd, comp, 0o755) == 0 else { break }
            let next = openat(fd, comp, O_RDONLY)
            close(fd)
            fd = next
            depth += 1
        }
        if fd >= 0 { close(fd) }
        report("overlong paths: \(depth) levels of 200 characters created through the volume")
        // Im Quellordner darf es nur volle Namen geben, Ebene für Ebene
        var dir = open(src.path, O_RDONLY)
        var stray: [String] = []
        var level = 0
        while dir >= 0 {
            guard let d = fdopendir(dup(dir)) else { break }
            var names: [String] = []
            while let e = readdir(d) {
                let name = withUnsafeBytes(of: e.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if name != "." && name != ".." && name != "Avid MediaFiles" { names.append(name) }
            }
            closedir(d)
            stray += names.filter { $0 != comp }.map { "level \(level): \($0.count) chars" }
            guard names.contains(comp) else { break }
            let next = openat(dir, comp, O_RDONLY)
            close(dir)
            dir = next
            level += 1
        }
        if dir >= 0 { close(dir) }
        #expect(stray.isEmpty, "truncated names in the source folder: \(stray)")
    }

    // MARK: Einhängen

    /// Schnell hintereinander einhängen und auswerfen: keine Reste in /Volumes, keine verwaisten Helfer.
    @Test func mountEjectCycles() throws {
        let src = try source("Stress Cycle")
        defer { cleanup(src) }
        let t = try seconds {
            for _ in 0..<25 {
                let w = try mounted(src)
                eject(w)
            }
        }
        report(String(format: "25 mount/eject cycles: %.1f s", t))
        // macOS entfernt den leeren Mountpunkt-Ordner mit etwas Verzögerung
        for _ in 0..<40 where fm.fileExists(atPath: "/Volumes/Stress Cycle") { Thread.sleep(forTimeInterval: 0.25) }
        #expect(!fm.fileExists(atPath: "/Volumes/Stress Cycle"))
        #expect(helperPID(src) == nil, "a helper is still running")
    }

    /// Viele Workspaces gleichzeitig einhängen (wie „Einhängen“ bei einem großen Projekt).
    @Test func parallelMounts() throws {
        let sources = try (0..<8).map { try source("Stress Par \($0)") }
        defer { sources.forEach(cleanup) }
        let workspaces = sources.map { Workspace(path: $0.path) }
        var errors: [String] = []
        let lock = NSLock()
        let t = seconds {
            DispatchQueue.concurrentPerform(iterations: workspaces.count) { i in
                do { try Mounter.mount(workspaces[i], helper: MountTests.helper) } catch { lock.withLock { errors.append("\(error)") } }
            }
        }
        report(String(format: "8 parallel mounts: %.1f s", t))
        #expect(errors.isEmpty, "\(errors)")
        #expect(workspaces.allSatisfy { Mounter.isMounted($0) })
        workspaces.forEach(eject)
    }

    /// Zwei Workspaces mit gleichem Ordnernamen (z. B. „MEDIA“ in zwei Projekten): nur der eingehängte gilt als eingehängt.
    @Test func sameFolderNameInTwoProjects() throws {
        let a = try source("Stress Same")
        let b = try source("Stress Same")
        defer { cleanup(a); cleanup(b) }
        let s = Store(directory: fm.temporaryDirectory.appendingPathComponent("mp-stress-\(UUID())"))
        s.add(a, to: nil)
        s.add(b, to: nil)
        let (wa, wb) = (s.library.workspaces[0], s.library.workspaces[1])
        try Mounter.mount(wa, helper: MountTests.helper)
        defer { eject(wa) }
        s.refresh()
        #expect(s.mounted.contains(wa.id))
        #expect(!s.mounted.contains(wb.id), "the other workspace with the same name shows as mounted – its Eject would eject this one")
    }

    /// Der Helfer stürzt ab (oder wird beendet): Mountpoint merkt es, wirft das tote Volume aus, erneutes Einhängen klappt.
    @Test func helperCrashIsNoticed() async throws {
        let src = try source("Stress Crash")
        defer { cleanup(src) }
        let s = Store(directory: fm.temporaryDirectory.appendingPathComponent("mp-stress-\(UUID())"))
        s.add(src, to: nil)
        let w = s.library.workspaces[0]
        try Mounter.mount(w, helper: MountTests.helper)
        s.refresh()
        #expect(s.mounted.contains(w.id))
        guard let pid = helperPID(src) else { Issue.record("helper not found"); eject(w); return }
        kill(pid, SIGKILL)
        for _ in 0..<40 where s.errors[w.id] == nil {
            try await Task.sleep(nanoseconds: 250_000_000)
            s.refresh()
        }
        #expect(s.errors[w.id] != nil, "no message 10 s after the helper died")
        #expect(!s.mounted.contains(w.id) && !Mounter.isMounted(w), "the dead volume is still mounted")
        if Mounter.isMounted(w) { _ = try? Mounter.run("/sbin/umount", ["-f", w.volumePath]) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try Mounter.mount(w, helper: MountTests.helper)
        #expect(Mounter.isMounted(w))
        eject(w)
    }

    /// Ein hängendes Laufwerk (hier: angehaltener Helfer, wie ein NAS, das nicht mehr antwortet)
    /// darf Mountpoint nicht einfrieren: die Prüfung „eingehängt?“ läuft alle 3 s im Hauptthread.
    @Test func hangingVolumeDoesNotBlockStatusCheck() throws {
        let src = try source("Stress Hang")
        defer { cleanup(src) }
        let w = try mounted(src)
        defer { eject(w) }
        Thread.sleep(forTimeInterval: 1)
        guard let pid = helperPID(src) else { Issue.record("helper not found"); return }
        kill(pid, SIGSTOP)
        let started = Date()
        let finished = Self.finishes(within: 3) { _ = Mounter.isMounted(w) }
        kill(pid, SIGCONT)
        report(String(format: "status check on a hanging volume: %@ after %.1f s", finished ? "done" : "still waiting", Date().timeIntervalSince(started)))
        #expect(finished, "the status check waits for the hanging volume – the menu bar app would freeze")
    }

    /// Ein Volume antwortet nicht mehr (NAS weg, von macOS noch nicht getrennt): nach etwa 10 s zeigt die Zeile
    /// „reagiert nicht“, und die Meldung verschwindet, sobald es wieder antwortet.
    @Test func stalledVolumeIsShownAndRecovers() async throws {
        let src = try source("Stress Stall")
        defer { cleanup(src) }
        let s = Store(directory: fm.temporaryDirectory.appendingPathComponent("mp-stress-\(UUID())"))
        s.add(src, to: nil)
        let w = s.library.workspaces[0]
        try Mounter.mount(w, helper: MountTests.helper)
        defer { eject(w) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        guard let pid = helperPID(src) else { Issue.record("helper not found"); return }
        kill(pid, SIGSTOP)
        for _ in 0..<40 where s.errors[w.id] == nil {
            try await Task.sleep(nanoseconds: 500_000_000)
            s.refresh()
        }
        #expect(s.errors[w.id] == Store.notResponding(w.name))
        kill(pid, SIGCONT)
        for _ in 0..<20 where s.errors[w.id] != nil {
            try await Task.sleep(nanoseconds: 500_000_000)
            s.refresh()
        }
        #expect(s.errors[w.id] == nil, "message stays after the volume answers again")
        #expect(s.mounted.contains(w.id))
    }

    /// „Auswerfen“, während das Laufwerk hängt: die App wartet nicht, das Volume geht, sobald es wieder antwortet.
    @Test func ejectWhileHangingDoesNotBlock() async throws {
        let src = try source("Stress Eject")
        defer { cleanup(src) }
        let s = Store(directory: fm.temporaryDirectory.appendingPathComponent("mp-stress-\(UUID())"))
        s.add(src, to: nil)
        let w = s.library.workspaces[0]
        try Mounter.mount(w, helper: MountTests.helper)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        s.refresh()
        guard let pid = helperPID(src) else { Issue.record("helper not found"); eject(w); return }
        kill(pid, SIGSTOP)
        let t = seconds { s.unmount(w) }
        report(String(format: "eject on a hanging volume returned after %.3f s", t))
        #expect(t < 0.2, "eject blocks the main thread")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        kill(pid, SIGCONT)
        for _ in 0..<40 where s.busy.contains(w.id) { try await Task.sleep(nanoseconds: 250_000_000) }
        #expect(!Mounter.isMounted(w), "not ejected after the volume answered again")
        if Mounter.isMounted(w) { eject(w) }
    }

    /// 6000 Dateien in einem MXF-Ordner: die Größenprüfung meldet ihn; die nächste Prüfung zählt nicht neu (nur stat).
    @Test func folderSizeCheck() async throws {
        let src = try source("Stress Size")
        defer { cleanup(src) }
        let folder = src.appendingPathComponent("Avid MediaFiles/MXF/1")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let made = seconds { for i in 0..<6000 { fm.createFile(atPath: folder.path + "/f\(i).mxf", contents: nil) } }
        let guardian = VolumeGuard(names: { [] }, numbered: { [] }, sizeRoots: { [SizeRoot(name: "Stress", root: src.path)] })
        var alerts: [Int] = []
        guardian.presentSize = { _, _, n in alerts.append(n) }
        func check() async throws -> Double {
            let started = Date()
            guardian.checkSizes()
            for _ in 0..<600 where !guardian.sizeIdle { try await Task.sleep(nanoseconds: 20_000_000) }
            return Date().timeIntervalSince(started)
        }
        let first = try await check()
        let again = try await check()
        report(String(format: "6000 files in MXF/1: created in %.1f s, first check %.3f s, unchanged folder %.3f s", made, first, again))
        #expect(alerts == [6000])
        guardian.acknowledgeSize(folder.path)
    }

    /// Auswerfen, während der Wächter das Volume beobachtet: das Auswerfen-Ereignis darf keinen Zugriff auslösen,
    /// der sich mit umount im Kernel verhakt (so blockierte es 2026-11-06 dauerhaft).
    @Test func ejectWhileGuardWatches() async throws {
        let src = try source("Stress Watch")
        defer { cleanup(src) }
        try fm.createDirectory(at: src.appendingPathComponent("Avid MediaFiles/MXF/1"), withIntermediateDirectories: true)
        let w = Workspace(path: src.path)
        let watch = FolderWatch(key: "stress:\(UUID())", name: w.name, mxf: w.volumePath + "/Avid MediaFiles/MXF", kind: .network, matches: { $0 == "1" })
        let guardian = VolumeGuard(names: { [] }, numbered: { [watch] })
        for round in 0..<10 {
            try Mounter.mount(w, helper: MountTests.helper)
            guardian.refresh()
            for _ in 0..<50 where !guardian.idle { try await Task.sleep(nanoseconds: 20_000_000) }
            try await Task.sleep(nanoseconds: 300_000_000)
            // wie im echten Betrieb: eine Datei ist noch offen, Auswerfen wird abgelehnt, dann geschlossen und erneut
            let file = w.volumePath + "/Avid MediaFiles/MXF/1/a\(round).mxf"
            try Data("x".utf8).write(to: URL(fileURLWithPath: file))
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
            let refused = Self.finishes(within: 15) { _ = try? Mounter.unmount(w) }
            #expect(refused, "refused eject hangs in round \(round)")
            if !refused { return }
            try handle.close()
            try await Task.sleep(nanoseconds: 300_000_000)
            var ejected = false
            for _ in 0..<20 where !ejected {
                // läuft in einem eigenen Thread: der Hauptthread muss frei bleiben, damit die Wächter-Ereignisse ankommen
                let done = Self.finishes(within: 15) { _ = try? Mounter.unmount(w) }
                #expect(done, "eject hangs in round \(round)")
                if !done { return }
                ejected = !Mounter.isMounted(w)
                if !ejected { try await Task.sleep(nanoseconds: 250_000_000) }
            }
            guardian.refresh()
        }
        report("10 ejects while the guard watches: all done")
    }

    /// Die Netzlaufwerk-Warnung fasst eigene Spiegel-Volumes nie an, sondern beobachtet ihren Quellordner, wenn der auf
    /// einem Netzlaufwerk liegt (auf dem NAS laufen lassen: MOUNTPOINT_STRESS_ROOT=/Volumes/<Freigabe>).
    @Test func networkWatchUsesSourceNotMirror() throws {
        let src = try source("Stress Net")
        defer { cleanup(src) }
        let d = UserDefaults.standard
        let before = d.object(forKey: "watchNetwork")
        defer { if let before { d.set(before, forKey: "watchNetwork") } else { d.removeObject(forKey: "watchNetwork") } }
        let s = Store(directory: fm.temporaryDirectory.appendingPathComponent("mp-stress-\(UUID())"))
        s.add(src, to: nil)
        let w = s.library.workspaces[0]
        try Mounter.mount(w, helper: MountTests.helper)
        defer { eject(w) }
        s.watchNetwork = true
        let watched = s.folderWatches().map(\.mxf)
        #expect(!watched.contains { $0.hasPrefix(w.volumePath + "/") }, "the mirror volume itself is watched")
        let onNetwork = Mounter.mounts().contains { !$0.local && !$0.own && w.path.hasPrefix($0.point + "/") }
        #expect(watched.contains(w.path + "/Avid MediaFiles/MXF") == onNetwork)
        report("network watch: mirror untouched, source " + (onNetwork ? "watched (network drive)" : "not watched (local)"))
    }

    /// Läuft `work` in einem eigenen Thread innerhalb der Frist durch? (nicht im MainActor des Tests)
    nonisolated static func finishes(within seconds: Double, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            work()
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success
    }

    // MARK: Wächter

    /// Tausende neue Ordner in MXF: keine Fehlalarme, genau ein Alarm für „1“, Hauptthread bleibt frei.
    @Test func guardUnderFolderStorm() async throws {
        let src = try source("Stress Guard")
        defer { cleanup(src) }
        let w = try mounted(src)
        defer { eject(w) }
        let mxf = w.volumePath + "/Avid MediaFiles/MXF"
        let watch = FolderWatch(key: "stress:\(UUID())", name: w.name, mxf: mxf, kind: .network, matches: { $0 == "1" })
        let guardian = VolumeGuard(names: { [] }, numbered: { [watch] })
        var alerts: [[String]] = []
        guardian.presentNumbered = { _, folders in alerts.append(folders) }
        guardian.refresh()
        for _ in 0..<50 where !guardian.idle { try await Task.sleep(nanoseconds: 50_000_000) }
        let t = try seconds {
            for i in 0..<2000 { try fm.createDirectory(atPath: mxf + "/Mac Studio.\(i + 2)", withIntermediateDirectories: false) }
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let main = seconds { guardian.refresh() }
        let started = Date()
        for _ in 0..<50 where !guardian.idle { try await Task.sleep(nanoseconds: 50_000_000) }
        report(String(format: "2000 folders in MXF: created in %.1f s, main thread %.3f s, background check %.3f s", t, main, Date().timeIntervalSince(started)))
        #expect(alerts.isEmpty)
        try fm.createDirectory(atPath: mxf + "/1", withIntermediateDirectories: false)
        for _ in 0..<30 where alerts.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(alerts == [["1"]])
        guardian.acknowledgeNumbered(watch, ["1"])
        #expect(main < 0.1, "a guard check blocks the main thread for \(main) s")
    }
}
