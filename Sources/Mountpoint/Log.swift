import AppKit

/// Logdatei `~/Library/Logs/Mountpoint/Mountpoint.log`: eine Zeile pro Ereignis, ab 1 MB nach `Mountpoint.old.log`.
/// Schreibt nur in der echten App (Tests berühren die Logdatei des Nutzers nicht). Fehler beim Schreiben halten nichts auf.
enum Log {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mountpoint")
    static let file = folder.appendingPathComponent("Mountpoint.log")
    private static let enabled = Bundle.main.bundleIdentifier == "io.github.moritz-poth.mountpoint"
    private static let queue = DispatchQueue(label: "Mountpoint.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        guard enabled else { return }
        let now = Date()
        queue.async {
            // DateFormatter nur in dieser Warteschlange: er ist nicht thread-sicher
            let line = "\(stamp.string(from: now)) \(message.replacingOccurrences(of: "\n", with: " | "))\n"
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: file.path)[.size] as? Int, size > 1_000_000 {
                let old = folder.appendingPathComponent("Mountpoint.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            if let h = try? FileHandle(forWritingTo: file) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: file.path) { write("log opened"); queue.sync {} }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
