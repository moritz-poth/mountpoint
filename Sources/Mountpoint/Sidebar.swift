import Foundation
import CoreServices

/// Eingehängte Workspaces in der Finder-Seitenleiste unter „Orte“. Der Finder zeigt dort die Liste FavoriteVolumes
/// (so trägt sich auch LucidLink ein); Netzlaufwerke ohne Server-Adresse – wie unsere – stehen sonst nirgends.
/// Die Liste behält Einträge ausgeworfener Volumes, darum trägt Mountpoint sie selbst wieder aus.
/// Angefasst werden nur Einträge, die Mountpoint angelegt hat (UserDefaults `sidebarOwned`, Volume-Pfade).
enum Sidebar {
    // eigene Warteschlange: beim Auflösen fremder Einträge (z. B. eines hängenden NAS) darf die App nicht einfrieren
    private static let queue = DispatchQueue(label: "Mountpoint.sidebar")
    private static let ownedKey = "sidebarOwned"
    @MainActor private static var applied: Set<String>?

    /// Soll-Zustand: genau diese Volume-Pfade stehen (von Mountpoint) unter „Orte“. Billig bei jedem Refresh –
    /// die Liste wird nur angefasst, wenn sich etwas geändert hat (und einmal nach dem Start: Reste nach einem Absturz).
    @MainActor static func sync(_ wanted: Set<String>) {
        guard wanted != applied else { return }
        applied = wanted
        queue.async { apply(wanted) }
    }

    /// Beim Beenden: alle eigenen Einträge entfernen, bevor der Prozess endet.
    @MainActor static func removeAll() {
        applied = []
        queue.sync { apply([]) }
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

    @available(macOS, deprecated: 10.11, message: "LSSharedFileList ist veraltet, aber die einzige Schnittstelle zur Seitenleiste (getestet unter macOS 15)")
    private static func apply(_ wanted: Set<String>) {
        var owned = Set(defaults.stringArray(forKey: ownedKey) ?? [])
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
            let name = (path as NSString).lastPathComponent
            // ausgeworfen: der Eintrag löst sich nicht mehr auf, dann zählt der Name
            // shortcut: ein fremder, ebenfalls nicht auflösbarer Eintrag mit genau diesem Volume-Namen würde mit entfernt – Pfad im Eintrag lesen, falls das je vorkommt
            for e in entries where e.path == path || (e.path == nil && e.name == name) {
                LSSharedFileListItemRemove(list, e.item)
            }
            owned.remove(path)
            Log.write("sidebar: removed \(path)")
        }
        for path in wanted.subtracting(owned) {
            guard !entries.contains(where: { $0.path == path }) else { continue }   // schon da (vom Nutzer): nicht übernehmen
            guard let last = items.last,
                  LSSharedFileListInsertItemURL(list, last, nil, nil, URL(fileURLWithPath: path) as CFURL, nil, nil) != nil else {
                Log.write("sidebar: could not add \(path)")
                continue
            }
            owned.insert(path)
            Log.write("sidebar: added \(path)")
        }
        defaults.set(owned.sorted(), forKey: ownedKey)
    }
}
