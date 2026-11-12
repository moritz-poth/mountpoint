import Foundation
import AppKit

/// Eingehängte Workspaces in der Finder-Seitenleiste unter „Orte“. Der Finder zeigt dort die Liste FavoriteVolumes
/// (so trägt sich auch LucidLink ein); Netzlaufwerke ohne Server-Adresse – wie unsere – stehen sonst nirgends.
/// Die Liste behält Einträge ausgeworfener Volumes (der Finder zeigt sie dann als „Geist“), darum trägt Mountpoint sie
/// selbst wieder aus. macOS löscht dabei nichts, es blendet nur aus (visibility 1 in der sfl3-Datei) – und der Schalter
/// „Externe Festplatten“ in den Finder-Einstellungen blendet alle wieder ein. Darum beobachtet Mountpoint die Liste
/// und blendet Geister mit Namen, die es je eingetragen hat (`sidebarNames`), sofort wieder aus.
/// Angefasst werden nur Einträge, die Mountpoint angelegt hat (UserDefaults `sidebarOwned`, Volume-Pfade) und eben diese Geister.
enum Sidebar {
    // eigene Warteschlange: beim Auflösen fremder Einträge (z. B. eines hängenden NAS) darf die App nicht einfrieren
    private static let queue = DispatchQueue(label: "Mountpoint.sidebar")
    private static let ownedKey = "sidebarOwned"
    /// Volume-Namen, die Mountpoint je eingetragen hat – wächst nur (ein ausgeblendeter Eintrag kann jederzeit wiederkommen)
    private static let namesKey = "sidebarNames"
    /// Name der Test-Volumes des Selbsttests (`probe`)
    static let probeName = "MPSelftest-Side"
    @MainActor private static var applied: Set<String>?
    @MainActor private static var known: Set<String> = []
    @MainActor private static var observed: LSSharedFileList?
    @MainActor private static var pending = false

    /// Soll-Zustand: genau diese Volume-Pfade stehen (von Mountpoint) unter „Orte“; `names` = Volume-Namen aller Workspaces
    /// (deren Geister werden ausgeblendet, auch wenn sie von einer älteren Version stammen). Billig bei jedem Refresh –
    /// die Liste wird nur angefasst, wenn sich etwas geändert hat (und einmal nach dem Start: Reste nach einem Absturz).
    @MainActor static func sync(_ wanted: Set<String>, names: Set<String>) {
        known = names
        if applied == nil {
            // einmal pro Start: alte Einträge wirklich löschen, erst danach beobachten (der Neustart des Dienstes trennt Beobachter)
            startCleanup(names) { observe() }
        }
        guard wanted != applied else { return }
        applied = wanted
        queue.async { apply(wanted, names: names) }
    }

    static var bundledCleanupURL: URL { mainBundleURL.appendingPathComponent("Contents/Helpers/Mountpoint Cleanup.app") }
    /// Gestartet wird eine Kopie außerhalb von Mountpoint.app: macOS rechnet Apps im Paket beim Vollzugriff der
    /// äußeren App zu (tccd-Protokoll, 2026-11-12), eine Kopie hier hat eigene Rechte. Wer sie verändert, ändert ihre
    /// Signatur – die Freigabe gilt dann nicht mehr.
    static let cleanupURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mountpoint/Mountpoint Cleanup.app")

    /// Kopie anlegen oder ersetzen, wenn sie fehlt oder nicht dieselbe ist (Programmdatei samt Signatur gleich)
    static func installCleanup(from source: URL = bundledCleanupURL, to target: URL = cleanupURL) throws {
        let exe = "Contents/MacOS/Mountpoint Cleanup"
        let new = try Data(contentsOf: source.appendingPathComponent(exe))
        if (try? Data(contentsOf: target.appendingPathComponent(exe))) == new { return }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = target.deletingLastPathComponent().appendingPathComponent(".cleanup-\(UUID().uuidString).app")
        try fm.copyItem(at: source, to: temp)
        do {
            // attributesOfItem folgt keinem Symlink: auch ein Link an dieser Stelle wird entfernt, nicht sein Ziel
            if (try? fm.attributesOfItem(atPath: target.path)) != nil { try fm.removeItem(at: target) }
            try fm.moveItem(at: temp, to: target)
        } catch { try? fm.removeItem(at: temp); throw error }
    }
    @MainActor private static var cleanupDone = false
    @MainActor private static var waiting: [@MainActor () -> Void] = []

    /// Nach dem Aufräumen dieses Starts (sofort, wenn es schon lief) – SidebarAccess braucht dessen Ergebnis
    @MainActor static func afterCleanup(_ f: @escaping @MainActor () -> Void) {
        cleanupDone ? f() : waiting.append(f)
    }

    /// Die sfl3-Datei braucht Festplattenvollzugriff. Den hat nur die Kopie von Mountpoint Cleanup.app (cleanupURL) –
    /// gestartet über LaunchServices, nicht als Kindprozess: nur so gilt sie für macOS als eigene App mit eigenen Rechten.
    /// Ihr erster abgelehnter Zugriff trägt sie ausgeschaltet in die Liste ein. Mountpoint selbst und der Helfer
    /// `mirror` bekommen keinen Vollzugriff (Sicherheitsprüfung 2026-11-11, docs/plan-1.4.0-full-disk-access.md).
    @MainActor private static func startCleanup(_ names: Set<String>, then: @escaping @MainActor () -> Void) {
        launchCleanup(["--names"] + names.sorted()) {
            cleanupDone = true
            then()
            waiting.forEach { $0() }
            waiting = []
        }
    }

    /// Hat Mountpoint Cleanup Festplattenvollzugriff? Startet sie nur zum Lesen (`--check`, löscht nichts).
    /// Entwicklungs-Builds ohne Helfer-Bundle: ja (dort fragt niemand nach).
    @MainActor static func checkAccess(_ done: @escaping @MainActor (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: bundledCleanupURL.path) else { done(true); return }
        launchCleanup(["--check"]) { done(defaults.object(forKey: accessKey) as? Bool == true) }
    }

    /// Kopie anlegen, starten (über LaunchServices, neue Instanz), auf ihr Ende warten (max. 30 s), ihr Ergebnis lesen
    @MainActor private static func launchCleanup(_ arguments: [String], then: @escaping @MainActor () -> Void) {
        func finish() {
            CFPreferencesAppSynchronize(mainBundleID as CFString)   // Ergebnis der Aufräum-App (record) lesen
            then()
        }
        // Entwicklungs-Builds ohne Helfer-Bundle: nicht aufräumen
        guard FileManager.default.fileExists(atPath: bundledCleanupURL.path) else { finish(); return }
        do { try installCleanup() } catch {
            Log.write("sidebar: cleanup could not be installed: \(error.localizedDescription)")
            finish(); return
        }
        defaults.removeObject(forKey: accessKey)   // kein Ergebnis eines früheren Laufs (oder von Mountpoint ≤ 1.3) verwenden
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = true   // läuft sie schon (Aufräumen beim Start), nicht nur diese wecken
        config.arguments = arguments
        NSWorkspace.shared.openApplication(at: cleanupURL, configuration: config) { app, error in
            if let error { Log.write("sidebar: cleanup could not be started: \(error.localizedDescription)") }
            let pid = app?.processIdentifier ?? 0
            queue.async {
                // der Dienst wird dort neu gestartet; erst danach beobachten
                let deadline = Date().addingTimeInterval(30)
                while pid > 0, kill(pid, 0) == 0, Date() < deadline { usleep(100_000) }
                DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
            }
        }
    }

    /// Läuft in Mountpoint Cleanup.app (cleanupMode): prüfen, Ergebnis für Mountpoint, Einstellungen und Selbsttest
    /// hinterlegen, aufräumen (mit `--check` nur prüfen). `--names` kommt von Mountpoint; ein gefälschter Name kann höchstens weitere eigene
    /// Einträge von Mountpoint löschen (isStale gilt weiter).
    static func runCleanup(arguments: [String]) {
        let names = Set(arguments.drop { $0 != "--names" }.dropFirst())
        let status = inspect(names: names)
        record(status)
        if arguments.contains("--check") {   // nur prüfen, ob sie lesen darf (SidebarAccess)
            CFPreferencesAppSynchronize(mainBundleID as CFString)
            return
        }
        switch status {
        case .success: _ = purge(names: names)
        case .failure(let problem): Log.write("sidebar: \(problem.reason), not cleaned")
        }
        CFPreferencesAppSynchronize(mainBundleID as CFString)
        Log.flush()
    }

    /// Ändert jemand die Liste (der Finder beim Umschalten seiner Einstellungen, der Nutzer, wir selbst): erneut abgleichen.
    @available(macOS, deprecated: 10.11)
    @MainActor private static func observe() {
        guard observed == nil, let list = LSSharedFileListCreate(nil, kLSSharedFileListFavoriteVolumes.takeUnretainedValue(), nil)?.takeRetainedValue() else { return }
        observed = list
        LSSharedFileListAddObserver(list, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Sidebar.changed() } }
        }, nil)
    }

    @MainActor private static func changed() {
        guard applied != nil, !pending else { return }
        pending = true
        // gebündelt: der Finder ändert beim Umschalten viele Einträge auf einmal; unsere eigenen Änderungen lösen
        // einen weiteren Durchlauf aus, der nichts mehr zu tun hat
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            pending = false
            guard let wanted = applied else { return }
            let names = known
            queue.async { apply(wanted, names: names) }
        }
    }

    /// Beim Beenden: alle eigenen Einträge entfernen, bevor der Prozess endet.
    /// Höchstens 5 s: hängt die Warteschlange (Bereinigung beim Start, ein hängendes NAS), endet Mountpoint trotzdem –
    /// übrig gebliebene Einträge löscht die Bereinigung beim nächsten Start.
    @MainActor static func removeAll() {
        applied = []
        let names = known
        let done = DispatchSemaphore(value: 0)
        queue.async { apply([], names: names); done.signal() }
        if done.wait(timeout: .now() + 5) == .timedOut { Log.write("sidebar: entries not removed at quit (busy), cleaned at next launch") }
    }

    /// Selbsttest: einen Eintrag für `path` anlegen und wieder entfernen – ohne die Liste der eigenen Einträge zu berühren.
    /// Wartet auf die Warteschlange, ohne den Haupt-Thread zu blockieren (beim ersten Start läuft dort die Bereinigung).
    static func probe(_ path: String) async -> (added: Bool, removed: Bool, note: String) {
        await withCheckedContinuation { done in queue.async { done.resume(returning: probeNow(path)) } }
    }

    @available(macOS, deprecated: 10.11)
    private static func probeNow(_ path: String) -> (added: Bool, removed: Bool, note: String) {
        guard let list = LSSharedFileListCreate(nil, kLSSharedFileListFavoriteVolumes.takeUnretainedValue(), nil)?.takeRetainedValue() else {
            return (false, false, "list not available")
        }
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        func items() -> [LSSharedFileListItem] {
            var seed: UInt32 = 0
            return (LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem]) ?? []
        }
        func find() -> LSSharedFileListItem? {
            items().first { (LSSharedFileListItemCopyResolvedURL($0, flags, nil)?.takeRetainedValue() as URL?)?.path == path }
        }
        guard let last = items().last else { return (false, false, "empty list") }
        guard LSSharedFileListInsertItemURL(list, last, nil, nil, URL(fileURLWithPath: path) as CFURL, nil, nil) != nil, let item = find() else {
            return (false, false, "insert failed")
        }
        LSSharedFileListItemRemove(list, item)
        return (true, find() == nil, "")
    }

    static let listFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteVolumes.sfl3")
    static let backupFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mountpoint/FavoriteVolumes-backup.sfl3")

    /// Ausblenden allein lässt die Liste wachsen (ein Eintrag pro Einhängen), und „Externe Festplatten“ holt alle zurück.
    /// Darum beim Start die eigenen Einträge ausgeworfener Volumes aus der sfl3-Datei löschen und den Dienst neu starten
    /// (er liest die Datei dann neu ein und schreibt beim Beenden nichts zurück; getestet macOS 15, 2026-11-10).
    /// Vorher Sicherungen: `backup` = die Liste vor dieser Bereinigung, `<backup>-first` einmalig = vor der allerersten.
    /// Fehlt die Datei, ist sie nicht lesbar oder ändert sie sich währenddessen: nichts anfassen, Ausblenden bleibt.
    /// Gibt die Zahl gelöschter Einträge zurück (nil: nicht bereinigt).
    @discardableResult
    static func purge(names workspaceNames: Set<String>, list: URL = listFile, backup: URL = backupFile,
                      exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                      restart: () -> Bool = restartDaemon) -> Int? {
        let names = purgeNames(workspaceNames)
        let read: (data: Data, root: [String: Any], items: [[String: Any]])
        switch readList(list) {
        case .failure(let problem): Log.write("sidebar: \(problem.reason), not cleaned"); return nil
        case .success(let r): read = r
        }
        let (data, items) = (read.data, read.items)
        var root = read.root
        let kept = items.filter { !isStale($0, names: names, exists: exists) }
        guard kept.count < items.count else { return 0 }
        root["items"] = kept
        do {
            let out = try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
            // inzwischen geändert (Finder, Nutzer): nichts schreiben, auch keine Sicherung – beim nächsten Start erneut
            guard (try? Data(contentsOf: list)) == data else { Log.write("sidebar: list changed meanwhile, not cleaned"); return nil }
            let first = backup.deletingPathExtension().appendingPathExtension("first.sfl3")
            if !FileManager.default.fileExists(atPath: first.path) { try writeNoFollow(data, to: first) }
            try writeNoFollow(data, to: backup)   // erst die Sicherungen; scheitern sie, bleibt die Liste unberührt
            try out.write(to: list, options: .atomic)
        } catch {
            Log.write("sidebar: could not clean list: \(error.localizedDescription)")
            return nil
        }
        let restarted = restart()
        // killall meldet auch „läuft gerade nicht“ als Fehler – dann liest der Dienst die neue Datei beim nächsten Start ohnehin
        Log.write("sidebar: deleted \(items.count - kept.count) old entries from the list (\(items.count) → \(kept.count))"
                  + (restarted ? "" : ", sharedfilelistd not restarted (not running, or killall failed)"))
        return items.count - kept.count
    }

    /// Schreibt `data` als `url`, ohne einem Symlink am Zielordner oder an der Datei zu folgen: die Aufräum-App hat
    /// Festplattenvollzugriff, und `~/Library/Application Support/Mountpoint` darf jedes Programm des Nutzers ändern –
    /// ein Symlink dort würde die Sicherung sonst in einen geschützten Ordner lenken. Der Ordner muss schon bestehen.
    static func writeNoFollow(_ data: Data, to url: URL) throws {
        func fail() -> Error { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let dir = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw fail() }
        defer { close(dir) }
        let name = url.lastPathComponent, temp = ".\(name).tmp"
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw fail() }
        let written = data.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) == $0.count }
        let closed = close(fd) == 0
        // renameat ersetzt einen Symlink am Ziel, statt ihm zu folgen
        guard written, closed, renameat(dir, temp, dir, name) == 0 else {
            let error = fail()
            unlinkat(dir, temp, 0)
            throw error
        }
    }

    struct ListProblem: Error {
        let reason: String
        /// macOS gibt den Ordner nur Apps mit Festplattenvollzugriff frei (Datenschutz, getestet macOS 15)
        var noAccess = false
    }

    /// Ergebnis der Prüfung beim Start – für die Einstellungs-App (eigene App, eigene Rechte: sie kann es nicht selbst prüfen)
    /// und den Selbsttest. `sidebarAccess` false = Festplattenvollzugriff fehlt.
    static let statusKey = "sidebarList", accessKey = "sidebarAccess"
    private static func record(_ status: Result<String, ListProblem>) {
        switch status {
        case .success(let summary): defaults.set("ok: " + summary, forKey: statusKey); defaults.set(true, forKey: accessKey)
        case .failure(let problem): defaults.set(problem.reason, forKey: statusKey); defaults.set(!problem.noAccess, forKey: accessKey)
        }
    }

    /// Liest die sfl3-Datei wie `purge` – auch für den Selbsttest, der so prüft, ob das Aufräumen auf diesem macOS geht.
    static func readList(_ list: URL = listFile) -> Result<(data: Data, root: [String: Any], items: [[String: Any]]), ListProblem> {
        let data: Data
        do { data = try Data(contentsOf: list) } catch {
            let denied = (error as NSError).code == NSFileReadNoPermissionError
            return .failure(ListProblem(reason: denied ? "no permission to read the list (Full Disk Access needed)" : "list file missing or not readable",
                                        noAccess: denied))
        }
        guard let u = try? NSKeyedUnarchiver(forReadingFrom: data) else { return .failure(ListProblem(reason: "list file not readable")) }
        u.requiresSecureCoding = false
        // ein Fehler (z. B. unbekannte Klasse in einem neuen Format) wirft einen Swift-Fehler statt die App abstürzen zu lassen
        u.decodingFailurePolicy = .setErrorAndReturn
        guard let root = (try? u.decodeTopLevelObject(forKey: NSKeyedArchiveRootObjectKey)) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return .failure(ListProblem(reason: "list file not readable")) }
        return .success((data, root, items))
    }

    /// Selbsttest, nur lesend: versteht Mountpoint die Liste, und trägt sie die Markierungen des Finders, an denen `isStale`
    /// fremde Einträge erkennt? Ohne sie (anderes macOS) könnte das Aufräumen Einträge des Finders für eigene halten.
    static func inspect(names workspaceNames: Set<String>, list: URL = listFile) -> Result<String, ListProblem> {
        switch readList(list) {
        case .failure(let problem): return .failure(problem)
        case .success(let r):
            let finders = r.items.filter {
                $0["Name"] != nil || ($0["CustomItemProperties"] as? [String: Any])?["com.apple.LSSharedFileList.DateLastSeen"] != nil
            }.count
            guard r.items.isEmpty || finders > 0 else {
                return .failure(ListProblem(reason: "\(r.items.count) entries, none with the Finder's markers – cleanup would not be safe"))
            }
            let stale = r.items.filter { isStale($0, names: purgeNames(workspaceNames)) }.count
            return .success("\(r.items.count) entries readable, \(finders) from the Finder, \(stale) stale")
        }
    }

    /// Namen, deren Einträge `purge` löschen und `apply` ausblenden darf: alle je eingetragenen, alle eigenen Pfade
    /// (auch von Versionen vor `sidebarNames`), alle Workspaces, der Selbsttest
    static func purgeNames(_ workspaceNames: Set<String>) -> Set<String> {
        Set(defaults.stringArray(forKey: namesKey) ?? [])
            .union((defaults.stringArray(forKey: ownedKey) ?? []).map { ($0 as NSString).lastPathComponent })
            .union(workspaceNames).union([probeName])
    }

    static func restartDaemon() -> Bool {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["sharedfilelistd"]
        guard (try? kill.run()) != nil else { return false }
        kill.waitUntilExit()
        return kill.terminationStatus == 0
    }

    /// shortcut: ein fremder Eintrag ohne Name/DateLastSeen direkt unter /Volumes mit einem unserer Namen würde gelöscht –
    /// keiner gesehen (LucidLink 3 liegt eine Ebene tiefer, direkt eingehängtes LucidLink hat Name); bei Bedarf Bookmark-Herkunft prüfen.
    /// Eintrag, den Mountpoint angelegt hat (die Einträge des Finders haben Name und DateLastSeen), für ein Volume mit
    /// einem unserer Namen, das gerade nicht eingehängt ist.
    static func isStale(_ item: [String: Any], names: Set<String>, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard item["Name"] == nil,
              (item["CustomItemProperties"] as? [String: Any])?["com.apple.LSSharedFileList.DateLastSeen"] == nil,
              let bookmark = item["Bookmark"] as? Data,
              let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path,
              (path as NSString).deletingLastPathComponent == "/Volumes",
              names.contains((path as NSString).lastPathComponent) else { return false }
        return !exists(path)
    }

    @available(macOS, deprecated: 10.11, message: "LSSharedFileList ist veraltet, aber die einzige Schnittstelle zur Seitenleiste (getestet unter macOS 15)")
    private static func apply(_ wanted: Set<String>, names workspaceNames: Set<String>) {
        var owned = Set(defaults.stringArray(forKey: ownedKey) ?? [])
        // eigene Pfade älterer Versionen (vor `sidebarNames`): Namen behalten, auch wenn der Pfad unten ausgetragen wird
        var names = Set(defaults.stringArray(forKey: namesKey) ?? []).union(owned.map { ($0 as NSString).lastPathComponent })
        let oldNames = Set(defaults.stringArray(forKey: namesKey) ?? [])
        guard let list = LSSharedFileListCreate(nil, kLSSharedFileListFavoriteVolumes.takeUnretainedValue(), nil)?.takeRetainedValue() else {
            Log.write("sidebar: list not available")
            return
        }
        var seed: UInt32 = 0
        let items = (LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem]) ?? []
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        let entries = items.map { item in
            (item: item,
             path: (LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL?)?.path,
             name: LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String)
        }

        for path in owned.subtracting(wanted) {
            for e in entries where e.path == path { LSSharedFileListItemRemove(list, e.item) }   // noch eingehängt (Einstellung aus)
            owned.remove(path)
            Log.write("sidebar: removed \(path)")
        }
        // Geister: ausgeworfen, der Eintrag löst sich nicht mehr auf, dann zählt der Name
        // shortcut: ein fremder, ebenfalls nicht auflösbarer Eintrag mit genau diesem Volume-Namen würde mit ausgeblendet – Pfad im Eintrag lesen, falls das je vorkommt
        let ghostNames = purgeNames(workspaceNames).union(names)   // names: schon um die eigenen Pfade ergänzt
            .subtracting(wanted.map { ($0 as NSString).lastPathComponent })
        let ghosts = entries.filter { $0.path == nil && ghostNames.contains($0.name) }
        for e in ghosts { LSSharedFileListItemRemove(list, e.item) }
        if !ghosts.isEmpty { Log.write("sidebar: hid \(ghosts.count) ejected: \(Set(ghosts.map(\.name)).sorted().joined(separator: ", "))") }
        for path in wanted.subtracting(owned) {
            guard !entries.contains(where: { $0.path == path }) else { continue }   // schon da (vom Nutzer): nicht übernehmen
            guard let last = items.last,
                  LSSharedFileListInsertItemURL(list, last, nil, nil, URL(fileURLWithPath: path) as CFURL, nil, nil) != nil else {
                Log.write("sidebar: could not add \(path)")
                continue
            }
            owned.insert(path)
            names.insert((path as NSString).lastPathComponent)
            Log.write("sidebar: added \(path)")
        }
        defaults.set(owned.sorted(), forKey: ownedKey)
        if names != oldNames { defaults.set(names.sorted(), forKey: namesKey) }
    }
}
