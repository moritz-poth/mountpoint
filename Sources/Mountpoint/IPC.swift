import Foundation

/// Nachrichten zwischen Mountpoint und der Einstellungs-App (DistributedNotificationCenter, nur auf diesem Mac).
/// "settings": Einstellungen geändert → neu lesen · "library": library.json geändert → neu laden ·
/// "launchAtLogin" (on=1/0, id) → Antwort "launchAtLoginResult" (on, error, id); "launchAtLoginQuery"; "showUpdate";
/// "noReopen" (Schließen wartet auf den Selbsttest: Panel danach nicht öffnen); "pane" (an die Einstellungs-App). Aufträge an Mountpoint, weil nur die App selbst das darf.
enum IPC {
    static let name = Notification.Name(mainBundleID + ".ipc")

    static func post(_ what: String, _ extra: [String: String] = [:]) {
        // geschriebene Einstellungen erst bereitstellen, dann melden
        CFPreferencesAppSynchronize(mainBundleID as CFString)
        var info = extra
        info["what"] = what
        info["pid"] = String(getpid())
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
    }

    /// Nachrichten der anderen Seite (eigene werden ignoriert)
    @discardableResult
    static func listen(_ handle: @escaping @MainActor (String, [String: String]) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { n in
            guard let info = n.userInfo as? [String: String], info["pid"] != String(getpid()), let what = info["what"] else { return }
            MainActor.assumeIsolated { handle(what, info) }
        }
    }
}
