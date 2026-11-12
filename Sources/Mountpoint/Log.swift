import AppKit

/// Logdatei `~/Library/Logs/Mountpoint/Mountpoint.log`: eine Zeile pro Ereignis, ab 1 MB nach `Mountpoint.old.log`.
/// Schreibt nur in der echten App (Tests berühren die Logdatei des Nutzers nicht). Fehler beim Schreiben halten nichts auf.
enum Log {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mountpoint")
    static let file = folder.appendingPathComponent("Mountpoint.log")
    private static let enabled = Bundle.main.bundleIdentifier?.hasPrefix(mainBundleID) == true   // App und Einstellungs-App
    private static let queue = DispatchQueue(label: "Mountpoint.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Zwei Prozesse (App und Einstellungs-App) schreiben dieselbe Datei: O_APPEND (eine Zeile = ein write, nichts
    /// überschreibt sich), Rotation unter einer Dateisperre; Zeilen der Einstellungs-App tragen „[settings]“.
    /// Wartet, bis alle Zeilen geschrieben sind – vor exit() der Aufräum-App
    static func flush() { queue.sync {} }

    static func write(_ message: String) {
        guard enabled else { return }
        let now = Date()
        queue.async {
            // DateFormatter nur in dieser Warteschlange: er ist nicht thread-sicher
            let tag = settingsMode ? " [settings]" : cleanupMode ? " [cleanup]" : ""
            let line = "\(stamp.string(from: now))\(tag) \(message.replacingOccurrences(of: "\n", with: " | "))\n"
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let lock = open(folder.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
            if lock >= 0 { flock(lock, LOCK_EX) }
            defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
            if let size = try? fm.attributesOfItem(atPath: file.path)[.size] as? Int, size > 1_000_000 {
                let old = folder.appendingPathComponent("Mountpoint.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
    }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: file.path) { write("log opened"); queue.sync {} }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
