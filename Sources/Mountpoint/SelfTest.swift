import AppKit
import CryptoKit
import Foundation

/// Selbsttest für Tester: prüft Einhängen, Dateien, Robustheit, Wächter und Updates auf einer eigenen Test-Festplatte
/// (Disk-Image im temporären Ordner). Die Workspaces und Daten des Nutzers werden nie angefasst; am Ende ist alles weg.
/// Ergebnis: `SelfTestReport` (JSON, anonymisiert) – der Nutzer sieht ihn vor dem Senden (Reporter.swift).
struct CheckResult: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case pass, fail, skip }
    let id: String
    let title: String
    var status: Status
    var seconds: Double
    var detail: String
}

struct SelfTestReport: Codable {
    var kind: String          // "selftest" | "problem"
    var app: String
    var build: String
    var date: String
    var system: [String: String]
    var results: [CheckResult]
    var durationSeconds: Double
    var log: [String]
    var note: String?
    var contact: String?
}

/// Ein Test wird übersprungen (z. B. macFUSE fehlt, Finder-Zugriff nicht erlaubt) – kein Fehler.
struct SkipCheck: Error { let reason: String }
struct CheckFailed: Error { let reason: String }

@MainActor
final class SelfTest: ObservableObject {
    static let shared = SelfTest()

    enum Phase: Equatable { case idle, running, done }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var results: [CheckResult] = []
    @Published private(set) var current: String?
    @Published var includeNAS = false
    /// nach Zustimmung (Consent) am Ende automatisch senden
    var autoSend = false
    @Published private(set) var sendOutcome: Reporter.Outcome?
    private(set) var report: SelfTestReport?
    var total: Int { checks.count }

    private let fm = FileManager.default
    private var base: URL!
    private var root: URL!          // eingehängtes Test-Image (oder Fallback: temporärer Ordner)
    private var imageMounted = false
    private var started = Date()

    /// Erste verbundene SMB-Freigabe, auf der getestet werden darf (nur mit Zustimmung, `includeNAS`).
    nonisolated static func nasRoot() -> String? {
        Mounter.mounts().first { $0.type == "smbfs" && !$0.hidden && FileManager.default.isWritableFile(atPath: $0.point) }?.point
    }

    // MARK: Ablauf

    struct Check {
        let id: String
        let title: String
        let run: @MainActor (SelfTest) async throws -> String
    }

    /// Sperrdatei für alle Prozesse dieses Benutzers: die Testvolumes heißen fest „MPSelftest-…“ und das Aufräumen
    /// wirft alle aus – zwei Tests gleichzeitig würden sich gegenseitig stören.
    private var lockFD: Int32 = -1
    /// läuft gerade in der App oder der Einstellungs-App schon einer
    @Published private(set) var blocked = false

    nonisolated static let lockPath = NSTemporaryDirectory() + "Mountpoint-Selftest.lock"

    /// läuft in irgendeinem Prozess (auch diesem) ein Selbsttest? – ein zweites open+flock scheitert dann
    nonisolated static var runningAnywhere: Bool {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }

    @discardableResult
    func start() -> Bool {
        guard phase != .running else { return false }
        let fd = open(Self.lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            blocked = true
            return false
        }
        lockFD = fd
        blocked = false
        phase = .running
        results = []
        report = nil
        sendOutcome = nil
        started = Date()
        Log.write("self-test started")
        Task { await runAll() }
        return true
    }

    func reset() { if phase == .done { phase = .idle; results = []; report = nil } }

    private func runAll() async {
        var system = Self.systemInfo()
        for c in checks {
            current = c.title
            let t = Date()
            var r = CheckResult(id: c.id, title: c.title, status: .pass, seconds: 0, detail: "")
            do { r.detail = try await c.run(self) }
            catch let s as SkipCheck { r.status = .skip; r.detail = s.reason }
            catch let f as CheckFailed { r.status = .fail; r.detail = f.reason }
            catch { r.status = .fail; r.detail = error.localizedDescription }
            r.seconds = (Date().timeIntervalSince(t) * 100).rounded() / 100
            results.append(r)
        }
        system["testDisk"] = imageMounted ? "disk image (APFS)" : "temporary folder"
        await cleanupAll()
        current = nil
        report = SelfTestReport(
            kind: "selftest", app: Updater.current, build: Self.build, date: ISO8601DateFormatter().string(from: Date()),
            system: system, results: results.map { var r = $0; r.detail = anonymize(r.detail); return r },
            durationSeconds: (Date().timeIntervalSince(started) * 10).rounded() / 10, log: Self.logTail(), note: nil, contact: nil)
        let failed = results.filter { $0.status == .fail }.count
        Log.write("self-test done: \(results.count) checks, \(failed) failed")
        if autoSend, let report {
            autoSend = false
            sendOutcome = await Reporter.send(report)
        }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        phase = .done
    }

    // MARK: Hilfen

    nonisolated static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev" }
    /// Helfer und Volume-Symbol aus dem App-Bundle (beim Entwickeln: aus .build)
    nonisolated static var helper: String {
        let inApp = mainBundleURL.appendingPathComponent("Contents/MacOS/mirror").path
        return FileManager.default.fileExists(atPath: inApp) ? inApp : ".build/helper/mirror"
    }
    nonisolated static var icon: String? {
        let path = mainBundleURL.appendingPathComponent("Contents/Resources/VolumeIcon.icns").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Blockierende Arbeit außerhalb des Hauptthreads: die App bleibt bedienbar.
    func off<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached { try work() }.value
    }

    nonisolated static func finishes(within seconds: Double, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { work(); done.signal() }
        return done.wait(timeout: .now() + seconds) == .success
    }

    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// Quellordner auf der Test-Festplatte; Volume-Name beginnt immer mit „MPSelftest“ (kollidiert nicht mit echten Laufwerken).
    func source(_ name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? root).appendingPathComponent("t-\(UUID().uuidString.prefix(4))").appendingPathComponent("MPSelftest-" + name)
        try fm.createDirectory(at: url.appendingPathComponent("Avid MediaFiles/MXF"), withIntermediateDirectories: true)
        return url
    }

    func mount(_ src: URL, network: Bool = true) async throws -> Workspace {
        try await mount(Workspace(path: src.path), network: network)
    }

    @discardableResult
    func mount(_ w: Workspace, network: Bool = true) async throws -> Workspace {
        let helper = Self.helper, icon = Self.icon
        try await off { try Mounter.mount(w, helper: helper, network: network, icon: icon) }
        return w
    }

    /// Auswerfen mit Wiederholung (macOS braucht einen Moment, bis ein frisches Volume registriert ist). Nie mit Gewalt.
    func eject(_ w: Workspace) async {
        for _ in 0..<20 {
            if (try? await off { try Mounter.unmount(w) }) != nil, !Mounter.isMounted(w) { return }
            await sleep(0.25)
        }
    }

    /// Prozess des Helfers über seine eindeutige fsname-Kennung (Mounter.run liefert nur stderr, pgrep schreibt nach stdout)
    nonisolated static func helperPID(_ w: Workspace) -> pid_t? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "fsname=" + Mounter.fsname(w)]
        p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n").first.flatMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    nonisolated static func random(_ count: Int) -> Data {
        var d = Data(count: count)
        d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return d
    }

    // MARK: Systeminfo (ohne persönliche Daten)

    static func systemInfo() -> [String: String] {
        func sysctl(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var buf = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname(name, &buf, &size, nil, 0)
            return String(cString: buf)
        }
        func plistVersion(_ path: String) -> String? {
            (NSDictionary(contentsOfFile: path)?["CFBundleShortVersionString"] as? String)
        }
        let fm = FileManager.default
        var s: [String: String] = [:]
        s["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
        s["model"] = sysctl("hw.model")
        s["cpu"] = sysctl("machdep.cpu.brand_string")
        s["arch"] = sysctl("hw.optional.arm64") == "" ? "x86_64" : "arm64"
        s["memoryGB"] = String(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        s["language"] = Locale.preferredLanguages.first ?? "?"
        s["appLanguage"] = defaults.string(forKey: "language") ?? "en"
        s["macFUSE"] = plistVersion(Mounter.macFUSE + "/Contents/Info.plist") ?? "not installed"
        let avid = (try? fm.contentsOfDirectory(atPath: "/Applications"))?.filter { $0.hasPrefix("Avid Media Composer") } ?? []
        s["mediaComposer"] = avid.isEmpty ? "not installed" : avid.compactMap { dir -> String? in
            let items = (try? fm.contentsOfDirectory(atPath: "/Applications/\(dir)")) ?? []
            let app = items.first { $0.hasSuffix(".app") && $0.replacingOccurrences(of: " ", with: "").contains("MediaComposer") }
            let version = app.flatMap { plistVersion("/Applications/\(dir)/\($0)/Contents/Info.plist") } ?? "installed"
            return version + (items.contains("Media Composer Enterprise") ? " (Enterprise folder present)" : "")
        }.joined(separator: ", ")
        s["lucidLink"] = fm.fileExists(atPath: "/Applications/Lucid.app") ? (plistVersion("/Applications/Lucid.app/Contents/Info.plist") ?? "installed") : "not installed"
        let mounts = Mounter.mounts()
        s["networkVolumes"] = String(mounts.filter { !$0.local && !$0.own }.count)
        s["mountpointVolumes"] = String(mounts.filter(\.own).count)
        // nur in der echten App: Store.shared liest die Bibliothek und richtet Seitenleiste/Wächter ein (Tests fassen das nie an)
        if Bundle.main.bundleIdentifier?.hasPrefix(mainBundleID) == true {
            s["workspaces"] = String(Store.shared.library.workspaces.count)
            s["networkDriveSetting"] = Store.shared.network ? "on" : "off"
            s["sidebarSetting"] = Store.shared.sidebar ? "on" : "off"
            s["testVersions"] = Store.shared.betas ? "on" : "off"
        }
        return s
    }

    nonisolated static func logTail(_ lines: Int = 150) -> [String] {
        guard let text = try? String(contentsOf: Log.file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(lines).map { anonymize(String($0)) }
    }

    // MARK: Aufräumen

    private func prepareRoot() async throws -> String {
        base = fm.temporaryDirectory.appendingPathComponent("Mountpoint-Selftest-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = base.appendingPathComponent("disk.sparseimage").path, mnt = base.appendingPathComponent("disk").path
        let stem = base.appendingPathComponent("disk").path
        try fm.createDirectory(atPath: mnt, withIntermediateDirectories: true)
        let made: Bool = try await off {
            guard (try? Mounter.run("/usr/bin/hdiutil", ["create", "-size", "2g", "-fs", "APFS", "-volname", "MPSelftestDisk", "-type", "SPARSE", stem]))?.0 == 0 else { return false }
            return (try? Mounter.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mnt, image]))?.0 == 0
        }
        if made {
            imageMounted = true
            root = URL(fileURLWithPath: mnt)
            return "APFS disk image, 2 GB (not shown in the Finder)"
        }
        root = base.appendingPathComponent("folder")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        throw CheckFailed(reason: "hdiutil could not create a test disk – tests run in a temporary folder instead")
    }

    private func cleanupAll() async {
        // eigene Test-Volumes, die noch hängen geblieben sind (nur „MPSelftest-…“)
        for m in Mounter.mounts() where m.own && (m.point as NSString).lastPathComponent.hasPrefix("MPSelftest-") {
            _ = try? await off { try Mounter.run("/sbin/umount", [m.point]) }
        }
        // leere Einhängepunkte der Test-Volumes, die macOS nicht entfernt hat (nur „MPSelftest-…“, nur leer).
        // /Volumes gehört root – löschen geht nicht, aber darüber einhängen und regulär auswerfen entfernt den Ordner.
        for name in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] where name.hasPrefix("MPSelftest-") {
            let p = "/Volumes/" + name
            guard !Mounter.isMountPoint(p), (try? fm.contentsOfDirectory(atPath: p))?.isEmpty == true, let base else { continue }
            let src = base.appendingPathComponent("cleanup").appendingPathComponent(name)
            try? fm.createDirectory(at: src, withIntermediateDirectories: true)
            let helper = Self.helper
            _ = try? await off {
                _ = try Mounter.run(helper, [src.path, p, "-o", "volname=\(fuseEscape(name)),fsname=mountpoint@selftest-cleanup"])
                Thread.sleep(forTimeInterval: 0.5)
                return try Mounter.run("/sbin/umount", [p])
            }
        }
        if imageMounted, let root {
            let path = root.path
            for _ in 0..<5 {
                if (try? await off { try Mounter.run("/usr/bin/hdiutil", ["detach", path]) })?.0 == 0 { break }
                await sleep(1)
            }
            imageMounted = false
        }
        if let base { let p = base.path; _ = try? await off { try Mounter.run("/bin/rm", ["-rf", p]) } }
    }

    // MARK: Tests

    var checks: [Check] {
        [
            Check(id: "system", title: "System") { _ in
                let s = Self.systemInfo()
                return "\(s["macOS"] ?? "?"), \(s["model"] ?? "?"), macFUSE \(s["macFUSE"] ?? "?")"
            },
            Check(id: "macfuse", title: "macFUSE installed") { _ in
                guard FileManager.default.fileExists(atPath: Mounter.macFUSE) else { throw CheckFailed(reason: "macFUSE is missing – most tests are skipped") }
                return SelfTest.systemInfo()["macFUSE"] ?? ""
            },
            Check(id: "testdisk", title: "Create test disk") { t in try await t.prepareRoot() },
            Check(id: "mount.network", title: "Mount as network drive") { t in
                try t.needFUSE()
                let src = try t.source("Net"), w = try await t.mount(src)
                let local = try URL(fileURLWithPath: w.volumePath).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
                guard local == false else { throw CheckFailed(reason: "volume reports itself as local") }
                await t.eject(w)
                guard !Mounter.isMounted(w) else { throw CheckFailed(reason: "could not be ejected") }
                for _ in 0..<50 where FileManager.default.fileExists(atPath: w.volumePath) { await t.sleep(0.1) }
                if FileManager.default.fileExists(atPath: w.volumePath) {
                    // ein leerer Rest ist harmlos (Mountpoint hängt darüber wieder ein) – melden, aber nicht als Fehler
                    let empty = (try? FileManager.default.contentsOfDirectory(atPath: w.volumePath))?.isEmpty == true
                    guard empty else { throw CheckFailed(reason: "a non-empty folder was left in /Volumes after ejecting") }
                    return "network volume; an empty mount point folder stayed in /Volumes after ejecting (harmless)"
                }
                return "network volume, ejected cleanly"
            },
            Check(id: "mount.local", title: "Mount as local drive") { t in
                try t.needFUSE()
                let w = try await t.mount(try t.source("Local"), network: false)
                let local = try URL(fileURLWithPath: w.volumePath).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
                await t.eject(w)
                guard local == true else { throw CheckFailed(reason: "volume does not report itself as local") }
                return "local volume"
            },
            Check(id: "volume.icon", title: "Volume icon") { t in
                try t.needFUSE()
                guard Self.icon != nil else { throw SkipCheck(reason: "no VolumeIcon.icns in this build") }
                let w = try await t.mount(try t.source("Icon"))
                let ok = FileManager.default.fileExists(atPath: w.volumePath + "/.VolumeIcon.icns")
                await t.eject(w)
                guard ok else { throw CheckFailed(reason: "the Finder shows the generic macFUSE drive") }
                return "own icon shown"
            },
            Check(id: "sidebar", title: "Finder sidebar entry") { t in
                try t.needFUSE()
                let w = try await t.mount(try t.source("Side"))
                let r = await Sidebar.probe(w.volumePath)
                await t.eject(w)
                guard r.added else { throw CheckFailed(reason: "could not add the volume under Locations (\(r.note))") }
                guard r.removed else { throw CheckFailed(reason: "entry could not be removed again (\(r.note))") }
                return "added and removed under Locations"
            },
            // nur lesend: zeigt auf einem neuen macOS, ob das Aufräumen der Seitenleiste dort funktionieren kann
            // was Mountpoint Cleanup beim letzten Start über die Liste herausfand (nur sie hat Festplattenvollzugriff)
            Check(id: "sidebar.list", title: "Finder sidebar cleanup") { _ in
                guard let status = defaults.string(forKey: Sidebar.statusKey) else { throw SkipCheck(reason: "Mountpoint has not checked the list yet") }
                if defaults.object(forKey: Sidebar.accessKey) as? Bool == false {
                    throw SkipCheck(reason: "Mountpoint Cleanup needs Full Disk Access to clean the list (Settings → General)")
                }
                guard status.hasPrefix("ok: ") else { throw CheckFailed(reason: status) }
                return String(status.dropFirst(4))
            },
            Check(id: "files.integrity", title: "Data integrity (64 files)") { t in
                try t.needFUSE()
                let src = try t.source("IO"), w = try await t.mount(src)
                let vol = w.volumePath, s = src.path
                let bad: Int = try await t.off {
                    var bad = 0
                    DispatchQueue.concurrentPerform(iterations: 64) { i in
                        let d = SelfTest.random(512 * 1024)
                        let f = "/Avid MediaFiles/MXF/f\(i).mxf"
                        try? d.write(to: URL(fileURLWithPath: vol + f))
                        let back = try? Data(contentsOf: URL(fileURLWithPath: vol + f)), direct = try? Data(contentsOf: URL(fileURLWithPath: s + f))
                        if back.map(SHA256.hash) != SHA256.hash(data: d) || direct.map(SHA256.hash) != SHA256.hash(data: d) { objc_sync_enter(SelfTest.self); bad += 1; objc_sync_exit(SelfTest.self) }
                    }
                    return bad
                }
                await t.eject(w)
                guard bad == 0 else { throw CheckFailed(reason: "\(bad) of 64 files differ after writing through the volume") }
                return "64 × 512 KB written in parallel, all checksums match"
            },
            Check(id: "files.throughput", title: "Throughput") { t in
                try t.needFUSE()
                let w = try await t.mount(try t.source("Speed"))
                let vol = w.volumePath
                let (wr, rd): (Double, Double) = try await t.off {
                    let chunk = SelfTest.random(8 * 1024 * 1024), path = vol + "/Avid MediaFiles/MXF/big.mxf"
                    FileManager.default.createFile(atPath: path, contents: nil)
                    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                    var t0 = Date()
                    for _ in 0..<32 { try h.write(contentsOf: chunk) }
                    try h.synchronize(); try h.close()
                    let wr = 256 / Date().timeIntervalSince(t0)
                    t0 = Date()
                    let r = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                    while let d = try r.read(upToCount: 8 * 1024 * 1024), !d.isEmpty {}
                    try r.close()
                    return (wr, 256 / Date().timeIntervalSince(t0))
                }
                await t.eject(w)
                return String(format: "256 MB: write %.0f MB/s, read %.0f MB/s", wr, rd)
            },
            Check(id: "files.metadata", title: "Create, rename, delete (1000 files)") { t in
                try t.needFUSE()
                let w = try await t.mount(try t.source("Meta"))
                let dir = w.volumePath + "/Avid MediaFiles/MXF"
                let secs: Double = try await t.off {
                    let fm = FileManager.default, t0 = Date()
                    for i in 0..<1000 {
                        let a = dir + "/m\(i).tmp", b = dir + "/m\(i).mxf"
                        guard fm.createFile(atPath: a, contents: Data([1])) else { throw CheckFailed(reason: "create failed at file \(i)") }
                        try fm.moveItem(atPath: a, toPath: b)
                        try fm.removeItem(atPath: b)
                    }
                    return Date().timeIntervalSince(t0)
                }
                await t.eject(w)
                return String(format: "%.1f s", secs)
            },
            Check(id: "files.names", title: "Unusual file names") { t in
                try t.needFUSE()
                let src = try t.source("Names"), w = try await t.mount(src)
                let names = ["Ümlaut äöü ß", "Café é", "日本語", "emoji 🎬", "space  double", "comma, semicolon;", "#hash%percent", "quote 'single'", String(repeating: "x", count: 250)]
                var missing: [String] = []
                for n in names {
                    try Data("x".utf8).write(to: URL(fileURLWithPath: w.volumePath + "/" + n))
                    if !FileManager.default.fileExists(atPath: src.path + "/" + n) { missing.append(n) }
                }
                await t.eject(w)
                guard missing.isEmpty else { throw CheckFailed(reason: "not found in the source folder: \(missing.joined(separator: " | "))") }
                return "\(names.count) names round-trip"
            },
            Check(id: "files.xattr", title: "Extended attributes") { t in
                try t.needFUSE()
                let w = try await t.mount(try t.source("Xattr"))
                let path = w.volumePath + "/a.mxf"
                FileManager.default.createFile(atPath: path, contents: Data([1]))
                let value = SelfTest.random(32 * 1024)
                let set = value.withUnsafeBytes { setxattr(path, "com.mountpoint.selftest", $0.baseAddress, value.count, 0, 0) }
                var back = Data(count: value.count)
                let got = back.withUnsafeMutableBytes { getxattr(path, "com.mountpoint.selftest", $0.baseAddress, value.count, 0, 0) }
                await t.eject(w)
                guard set == 0 else { throw CheckFailed(reason: "setxattr: \(String(cString: strerror(errno)))") }
                guard got == value.count, back == value else { throw CheckFailed(reason: "attribute changed on the way") }
                return "32 KB attribute round-trips"
            },
            Check(id: "files.longpaths", title: "Overlong paths are never truncated") { t in
                try t.needFUSE()
                let src = try t.source("Long"), w = try await t.mount(src)
                let comp = String(repeating: "a", count: 200)
                var fd = open(w.volumePath, O_RDONLY), depth = 0
                while fd >= 0, depth < 12, mkdirat(fd, comp, 0o755) == 0 {
                    let next = openat(fd, comp, O_RDONLY); close(fd); fd = next; depth += 1
                }
                if fd >= 0 { close(fd) }
                // im Quellordner: nur volle Namen
                var path = src.path, stray = false
                for _ in 0..<depth {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: path))?.filter { $0 != "Avid MediaFiles" } ?? []
                    if names.contains(where: { $0 != comp }) { stray = true; break }
                    path += "/" + comp
                }
                await t.eject(w)
                guard !stray else { throw CheckFailed(reason: "a truncated folder name appeared in the source folder") }
                return "\(depth) levels of 200 characters, no truncation"
            },
            Check(id: "eject.busy", title: "Eject with an open file") { t in
                try t.needFUSE()
                let w = try await t.mount(try t.source("Busy"))
                let file = w.volumePath + "/open.mxf"
                try Data("x".utf8).write(to: URL(fileURLWithPath: file))
                let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
                var message = ""
                do { try await t.off { try Mounter.unmount(w) }; message = "" } catch { message = error.localizedDescription }
                try h.close()
                await t.eject(w)
                guard !message.isEmpty else { throw CheckFailed(reason: "the volume was ejected although a file was open") }
                guard !Mounter.isMounted(w) else { throw CheckFailed(reason: "could not be ejected after closing the file") }
                return "refused while busy, ejected afterwards"
            },
            Check(id: "mount.cycles", title: "10 mount/eject cycles") { t in
                try t.needFUSE()
                let src = try t.source("Cycle"), t0 = Date()
                for i in 0..<10 {
                    let w = try await t.mount(src)
                    await t.eject(w)
                    guard !Mounter.isMounted(w) else { throw CheckFailed(reason: "cycle \(i + 1): still mounted") }
                }
                return String(format: "%.1f s", Date().timeIntervalSince(t0))
            },
            Check(id: "mount.parallel", title: "4 parallel mounts") { t in
                try t.needFUSE()
                let srcs = try (0..<4).map { try t.source("Par\($0)") }
                let helper = Self.helper, t0 = Date()
                let ws = srcs.map { Workspace(path: $0.path) }
                let errors: [String] = try await t.off {
                    var errs: [String] = []
                    DispatchQueue.concurrentPerform(iterations: ws.count) { i in
                        do { try Mounter.mount(ws[i], helper: helper) } catch { objc_sync_enter(SelfTest.self); errs.append(error.localizedDescription); objc_sync_exit(SelfTest.self) }
                    }
                    return errs
                }
                let up = ws.filter { Mounter.isMounted($0) }.count
                for w in ws { await t.eject(w) }
                guard errors.isEmpty, up == 4 else { throw CheckFailed(reason: "\(up) of 4 mounted. \(errors.joined(separator: " | "))") }
                return String(format: "%.1f s", Date().timeIntervalSince(t0))
            },
            Check(id: "mount.samename", title: "Two folders with the same name") { t in
                try t.needFUSE()
                let a = try t.source("Same"), b = try t.source("Same")
                let wa = try await t.mount(a)
                var refused = false
                do { _ = try await t.mount(b) } catch { refused = true }
                let wb = Workspace(path: b.path)
                let wrong = Mounter.isMounted(wb)
                await t.eject(wa)
                guard refused, !wrong else { throw CheckFailed(reason: "the second folder was not refused or shows as mounted") }
                return "second one refused with a message, statuses kept apart"
            },
            Check(id: "helper.crash", title: "Crashed helper is noticed") { t in
                try t.needFUSE()
                let src = try t.source("Crash")
                let s = Store(directory: t.base.appendingPathComponent("store-\(UUID().uuidString.prefix(4))"))
                s.add(src, to: nil)
                let w = s.library.workspaces[0]
                try await t.mount(w)
                s.refresh()
                guard let pid = Self.helperPID(w) else { await t.eject(w); throw CheckFailed(reason: "helper process not found") }
                kill(pid, SIGKILL)
                for _ in 0..<40 where s.errors[w.id] == nil { await t.sleep(0.25); s.refresh() }
                let noticed = s.errors[w.id] != nil
                if Mounter.isMounted(w) { _ = try? await t.off { try Mounter.run("/sbin/umount", ["-f", w.volumePath]) } }
                guard noticed else { throw CheckFailed(reason: "no message 10 s after the helper died") }
                return "noticed, dead volume removed"
            },
            Check(id: "volume.hanging", title: "Hanging drive does not freeze the app") { t in
                try t.needFUSE()
                let src = try t.source("Hang")
                let s = Store(directory: t.base.appendingPathComponent("store-\(UUID().uuidString.prefix(4))"))
                s.add(src, to: nil)
                let w = s.library.workspaces[0]
                try await t.mount(w)
                await t.sleep(1)
                s.refresh()
                guard let pid = Self.helperPID(w) else { await t.eject(w); throw CheckFailed(reason: "helper process not found") }
                kill(pid, SIGSTOP)
                let status = Self.finishes(within: 3) { _ = Mounter.isMounted(w) }
                let t0 = Date()
                s.unmount(w)
                let ejectReturned = Date().timeIntervalSince(t0)
                await t.sleep(1.5)
                kill(pid, SIGCONT)
                for _ in 0..<40 where s.busy.contains(w.id) { await t.sleep(0.25) }
                if Mounter.isMounted(w) { await t.eject(w) }
                guard status else { throw CheckFailed(reason: "status check waits for the hanging drive") }
                guard ejectReturned < 0.3 else { throw CheckFailed(reason: String(format: "Eject blocked the app for %.1f s", ejectReturned)) }
                return String(format: "status check instant, Eject returned after %.2f s", ejectReturned)
            },
            Check(id: "guard.protected", title: "Protected volume alert") { t in
                try t.needFUSE()
                let src = try t.source("Guard")
                try FileManager.default.removeItem(at: src.appendingPathComponent("Avid MediaFiles"))
                let w = try await t.mount(src)
                var fired = false
                let guardian = VolumeGuard(names: { [w.name] }, numbered: { [] }, sizeRoots: { [] }, persist: false)
                guardian.present = { _ in fired = true }
                guardian.refresh()
                for _ in 0..<50 where !guardian.idle { await t.sleep(0.05) }
                try FileManager.default.createDirectory(atPath: w.volumePath + "/Avid MediaFiles", withIntermediateDirectories: false)
                for _ in 0..<60 where !fired { await t.sleep(0.1) }
                await t.eject(w)
                guard fired else { throw CheckFailed(reason: "no alert within 6 s after “Avid MediaFiles” appeared") }
                return "alert within seconds"
            },
            Check(id: "guard.numbered", title: "“1” folder warning") { t in
                try t.needFUSE()
                let w = try await t.mount(try t.source("One"))
                let mxf = w.volumePath + "/Avid MediaFiles/MXF"
                let watch = FolderWatch(key: "selftest:\(UUID())", name: w.name, mxf: mxf, kind: .network, matches: { $0 == "1" })
                var got: [String] = []
                let guardian = VolumeGuard(names: { [] }, numbered: { [watch] }, sizeRoots: { [] }, persist: false)
                guardian.presentNumbered = { _, new in got += new }
                guardian.refresh()
                for _ in 0..<50 where !guardian.idle { await t.sleep(0.05) }
                for n in ["2", "abc", "1"] { try FileManager.default.createDirectory(atPath: mxf + "/" + n, withIntermediateDirectories: false) }
                for _ in 0..<60 where got.isEmpty { await t.sleep(0.1) }
                await t.eject(w)
                guard got == ["1"] else { throw CheckFailed(reason: got.isEmpty ? "no warning within 6 s" : "warned about \(got)") }
                return "warned only about “1”"
            },
            Check(id: "guard.size", title: "MXF folder size warning") { t in
                let src = try t.source("Size")
                let folder = src.appendingPathComponent("Avid MediaFiles/MXF/1").path
                try await t.off {
                    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                    for i in 0..<5100 { FileManager.default.createFile(atPath: folder + "/f\(i).mxf", contents: nil) }
                }
                var alerts: [Int] = []
                let guardian = VolumeGuard(names: { [] }, numbered: { [] }, sizeRoots: { [SizeRoot(name: "MPSelftest", root: src.path)] }, persist: false)
                guardian.presentSize = { _, _, n in alerts.append(n) }
                let t0 = Date()
                guardian.checkSizes()
                for _ in 0..<600 where !guardian.sizeIdle { await t.sleep(0.02) }
                let secs = Date().timeIntervalSince(t0)
                guardian.acknowledgeSize(folder)
                guard alerts == [5100] else { throw CheckFailed(reason: "expected one alert for 5100 files, got \(alerts)") }
                return String(format: "5100 files counted in %.2f s", secs)
            },
            Check(id: "update.signature", title: "Update download and signature") { t in
                var req = URLRequest(url: Updater.api)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw SkipCheck(reason: "GitHub not reachable")
                }
                guard let release = newestRelease(fromJSON: data, includePrereleases: true), let sigURL = release.signature else {
                    throw CheckFailed(reason: "no signed release found")
                }
                let (zip, _) = try await URLSession.shared.data(from: release.zip)
                let (sig, _) = try await URLSession.shared.data(from: sigURL)
                guard Updater.signatureValid(zip, sig) else { throw CheckFailed(reason: "signature of \(release.tag) is not valid") }
                return "\(release.tag): \(zip.count / 1024) KB, signature valid"
            },
            Check(id: "nas", title: "Network share (NAS)") { t in
                try t.needFUSE()
                guard t.includeNAS, let nas = Self.nasRoot() else { throw SkipCheck(reason: t.includeNAS ? "no connected network share" : "not selected") }
                let dir = URL(fileURLWithPath: nas).appendingPathComponent(".mountpoint-selftest-\(UUID().uuidString.prefix(4))")
                defer { let p = dir.path; Task.detached { _ = try? Mounter.run("/bin/rm", ["-rf", p]) } }
                let src = try t.source("NAS", in: dir), w = try await t.mount(src)
                let vol = w.volumePath, s = src.path
                let bad: Int = try await t.off {
                    var bad = 0
                    for i in 0..<8 {
                        let d = SelfTest.random(1024 * 1024), f = "/Avid MediaFiles/MXF/n\(i).mxf"
                        try d.write(to: URL(fileURLWithPath: vol + f))
                        if (try? Data(contentsOf: URL(fileURLWithPath: s + f))) != d { bad += 1 }
                    }
                    return bad
                }
                await t.eject(w)
                guard bad == 0 else { throw CheckFailed(reason: "\(bad) of 8 files differ on the share") }
                return "8 MB through a workspace on the share, checksums match"
            },
        ]
    }

    private func needFUSE() throws {
        guard FileManager.default.fileExists(atPath: Mounter.macFUSE) else { throw SkipCheck(reason: "macFUSE is not installed") }
        guard root != nil else { throw SkipCheck(reason: "no test disk") }
    }
}

// MARK: Anonymisieren

/// Ersetzt Benutzername, Rechnername und eigene Ordner-/Volume-Namen in Pfaden durch kurze Kennungen.
/// Fachliche Namen (Avid MediaFiles, MXF, Testordner …) bleiben stehen, damit der Bericht lesbar bleibt.
/// Ordnernamen mit Leerzeichen werden ganz erfasst – lieber ein Wort zu viel ersetzt als ein Name im Bericht.
func anonymize(_ text: String) -> String {
    var t = text
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    t = t.replacingOccurrences(of: home, with: "~")
    let user = NSUserName()
    if user.count > 2 { t = t.replacingOccurrences(of: user, with: "<user>") }
    if let host = Host.current().localizedName, host.count > 2 { t = t.replacingOccurrences(of: host, with: "<computer>") }
    // Server-Adressen (smb://user@nas/share): Schema bleibt, Benutzer, Server und Freigabe werden Kennungen
    if let urlRe = try? NSRegularExpression(pattern: #"\b(smb|afp|nfs|cifs)://[^\s)"',]+"#, options: [.caseInsensitive]) {
        let ns = t as NSString
        for m in urlRe.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
            let scheme = ns.substring(with: m.range(at: 1))
            let h = SHA256.hash(data: Data(ns.substring(with: m.range).utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
            t = (t as NSString).replacingCharacters(in: m.range, with: "\(scheme)://<server-\(h)>")
        }
    }
    let keep: Set<String> = ["Avid MediaFiles", "MXF", "1", "Library", "Logs", "Mountpoint", "Application Support", "Volumes", "Users", "Shared",
                             "AvidMediaComposer", "Macintosh HD", "tmp", "private", "var", "folders"]
    guard let re = try? NSRegularExpression(pattern: #"(/Volumes/|~/|/Users/)([^\s,:"'|()]+(?: (?!→)[^\s,:"'|()]+)*)"#) else { return t }
    let ns = t as NSString
    var out = ""
    var last = 0
    for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        out += ns.substring(with: m.range(at: 1))
        let parts = ns.substring(with: m.range(at: 2)).split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            let p = String(part)
            if p.isEmpty || keep.contains(p) || p.hasPrefix("MPSelftest") || p.hasPrefix("Mountpoint") || p.hasPrefix("<") { return p }
            let h = SHA256.hash(data: Data(p.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
            return "n" + h
        }
        out += parts.joined(separator: "/")
        last = m.range.location + m.range.length
    }
    out += ns.substring(from: last)
    return out
}
