import Foundation
import CoreServices

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
            queue.async { purge(names: names); DispatchQueue.main.async { observe() } }
        }
        guard wanted != applied else { return }
        applied = wanted
        queue.async { apply(wanted, names: names) }
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
    @MainActor static func removeAll() {
        applied = []
        let names = known
        queue.sync { apply([], names: names) }
    }

    /// Selbsttest: einen Eintrag für `path` anlegen und wieder entfernen – ohne die Liste der eigenen Einträge zu berühren.
    static func probe(_ path: String) -> (added: Bool, removed: Bool, note: String) {
        queue.sync { probeNow(path) }
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

    private static let listFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteVolumes.sfl3")

    /// Ausblenden allein lässt die Liste wachsen (ein Eintrag pro Einhängen), und „Externe Festplatten“ holt alle zurück.
    /// Darum beim Start die eigenen Einträge ausgeworfener Volumes aus der sfl3-Datei löschen und den Dienst neu starten
    /// (er liest die Datei dann neu ein; getestet macOS 15, 2026-11-10). Vorher eine Sicherung in Application Support/Mountpoint.
    /// Kann die Datei nicht gelesen werden (anderes Format, andere macOS-Version): nichts anfassen, Ausblenden bleibt.
    private static func purge(names workspaceNames: Set<String>) {
        let names = Set(defaults.stringArray(forKey: namesKey) ?? []).union(workspaceNames).union([probeName])
        guard let data = try? Data(contentsOf: listFile),
              let u = try? NSKeyedUnarchiver(forReadingFrom: data) else { return }
        u.requiresSecureCoding = false
        guard var root = u.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { Log.write("sidebar: list file not readable, not cleaned"); return }
        let kept = items.filter { !isStale($0, names: names) }
        guard kept.count < items.count else { return }
        root["items"] = kept
        let backup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mountpoint/FavoriteVolumes-backup.sfl3")
        do {
            let out = try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
            try data.write(to: backup, options: .atomic)
            try out.write(to: listFile, options: .atomic)
        } catch {
            Log.write("sidebar: could not clean list: \(error.localizedDescription)")
            return
        }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["sharedfilelistd"]
        try? kill.run()
        kill.waitUntilExit()
        Log.write("sidebar: deleted \(items.count - kept.count) old entries from the list (\(items.count) → \(kept.count))")
    }

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
        var names = Set(defaults.stringArray(forKey: namesKey) ?? [])
        let oldNames = names
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
        let ghostNames = names.union(workspaceNames).union(owned.map { ($0 as NSString).lastPathComponent }).union([probeName])
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
