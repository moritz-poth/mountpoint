import Foundation
import NetFS

struct MountError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Einhängen und Auswerfen. Läuft im Hintergrund (blockierende Aufrufe), darum ohne Zustand.
enum Mounter {
    static let macFUSE = "/Library/Filesystems/macfuse.fs"

    struct Mount {
        let point: String
        let from: String
        let local: Bool
        let hidden: Bool
        /// Dateisystem, z. B. "smbfs", "apfs", "macfuse"
        var type = ""
        /// von Mountpoint eingehängt (auch von älteren Versionen ohne Kennung)
        var own: Bool { from.hasPrefix("mountpoint@") || from.hasPrefix("mirror@") }
    }

    /// Alle eingehängten Volumes aus der Liste des Systems. MNT_NOWAIT fragt kein Laufwerk –
    /// ein hängendes NAS kann Mountpoint so nicht einfrieren.
    static func mounts() -> [Mount] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let empty = statfs()
        var list = Array(repeating: empty, count: Int(count) + 8)
        let size = Int32(list.count * MemoryLayout.stride(ofValue: empty))
        let n = list.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, size, MNT_NOWAIT) }
        func text<T>(_ t: T) -> String { withUnsafeBytes(of: t) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } }
        var result: [Mount] = []
        for s in list.prefix(Int(max(n, 0))) {
            let flags = UInt64(s.f_flags)
            result.append(Mount(point: text(s.f_mntonname), from: text(s.f_mntfromname),
                                local: flags & UInt64(MNT_LOCAL) != 0, hidden: flags & UInt64(MNT_DONTBROWSE) != 0, type: text(s.f_fstypename)))
        }
        return result
    }

    /// Kennung, unter der der Helfer das Volume einhängt (statt "mirror@macfuse0")
    static func fsname(_ w: Workspace) -> String { "mountpoint@" + w.id.uuidString }

    /// Genau dieser Workspace ist eingehängt – nicht ein anderer mit gleichem Ordnernamen.
    static func isMounted(_ w: Workspace, in table: [Mount] = mounts()) -> Bool {
        guard let m = table.first(where: { $0.point == w.volumePath }), m.own else { return false }
        return m.from == fsname(w) || m.from.hasPrefix("mirror@")   // ältere Versionen: nur nach Pfad
    }

    static func isMountPoint(_ path: String, in table: [Mount] = mounts()) -> Bool {
        table.contains { $0.point == path }
    }

    /// `network`: ohne das macFUSE-Flag `local` meldet macOS das Volume als Netzlaufwerk; Media Composer Enterprise
    /// legt dann wie auf geteiltem Speicher einen Ordner "<Rechnername>.1" statt "1" an (getestet mit MC 2026.8).
    /// `icon`: Volume-Symbol im Finder (sonst zeigt macFUSE sein „FUSE“-Laufwerk).
    static func mount(_ w: Workspace, helper: String, network: Bool = true, icon: String? = nil) throws {
        if isMounted(w) { return }
        guard FileManager.default.fileExists(atPath: macFUSE) else {
            throw MountError(message: loc("macFUSE is not installed. Install it from macfuse.github.io (Mimiq installs it too), then try again."))
        }
        let source = try resolveSource(w)
        // Ein leerer Ordner ohne Mount ist nur ein Rest (z. B. nach einem Absturz); darüber darf eingehängt werden.
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: w.volumePath))?.isEmpty == true
        if FileManager.default.fileExists(atPath: w.volumePath) && !leftover {
            throw MountError(message: loc("Another drive named “\(w.name)” is already connected. Eject it first – two volumes cannot have the same name."))
        }

        // Der Helfer kehrt zurück, sobald das Volume steht, und läuft dann im Hintergrund weiter.
        var options = "volname=\(fuseEscape(w.name)),fsname=\(fsname(w))" + (network ? "" : ",local")
        if let icon { options += ",volicon=\(fuseEscape(icon))" }
        let (status, msg) = try run(helper, [source, w.volumePath, "-o", options])
        guard status == 0, isMounted(w) else {
            throw MountError(message: explainMountFailure(msg, name: w.name))
        }
    }

    /// Ausgabe des Helfers in eine verständliche Meldung übersetzen; die Technik-Details hängen hinten an.
    static func explainMountFailure(_ output: String, name: String) -> String {
        let o = output.lowercased()
        let text: String
        if o.contains("not available") || o.contains("load") && o.contains("fuse") || o.contains("extension") {
            text = loc("macFUSE could not be loaded. Allow its system extension under System Settings → Privacy & Security, restart the Mac and try again.")
        } else if o.contains("library folder") {
            text = loc("“\(name)” is in the Library folder of your user account. Mountpoint does not mount folders from there – it holds the data of Mail, Messages and other apps. Move the folder somewhere else.")
        } else if o.contains("permission denied") || o.contains("operation not permitted") {
            text = loc("Mountpoint is not allowed to read the folder of “\(name)”. Check the folder’s permissions or allow Mountpoint under System Settings → Privacy & Security → Files and Folders.")
        } else {
            text = loc("“\(name)” could not be mounted.")
        }
        return output.isEmpty ? text : text + "\n" + loc("Details: \(output)")
    }

    /// Nie mit Gewalt auswerfen: hat Avid noch Dateien offen, bleibt das Volume eingehängt.
    static func unmount(_ w: Workspace) throws {
        guard isMounted(w) else { return }
        // /sbin/umount statt unmount(2): nur so entfernt macOS danach den leeren Ordner in /Volumes
        var (status, msg) = try run("/sbin/umount", [w.volumePath])
        // belegt: noch einmal über DiskArbitration wie der Finder – die fragt die Programme, und z. B. die Finder-Vorschau
        // (QuickLook) gibt ihre Datei frei; echt geöffnete Dateien blockieren weiter (getestet 2026-11-13). Nie mit Gewalt.
        if status != 0, msg.localizedCaseInsensitiveContains("busy") {
            status = try run("/usr/sbin/diskutil", ["unmount", w.volumePath]).0
        }
        guard status == 0 else {
            throw MountError(message: msg.localizedCaseInsensitiveContains("busy")
                ? loc("“\(w.name)” is still in use – an app has files on it open (e.g. Media Composer). Close them and try again.")
                : loc("“\(w.name)” could not be ejected.") + (msg.isEmpty ? "" : "\n" + loc("Details: \(msg)")))
        }
    }

    /// Startet ein Programm und wartet. Gibt Status und Fehlerausgabe zurück, mit `output` die Standardausgabe (sonst verworfen).
    static func run(_ exe: String, _ args: [String], output: Bool = false) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        if output { p.standardOutput = pipe } else { p.standardOutput = FileHandle.nullDevice; p.standardError = pipe }
        do { try p.run() } catch {
            throw MountError(message: loc("Mountpoint’s helper program could not be started. Please reinstall Mountpoint.") + "\n" + loc("Details: \(error.localizedDescription)"))
        }
        p.waitUntilExit()
        let msg = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Ordner auf einem NAS: Freigabe bei Bedarf selbst einhängen (Zugangsdaten aus dem Schlüsselbund, sonst fragt macOS).
    static func resolveSource(_ w: Workspace) throws -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: w.path, isDirectory: &isDir), isDir.boolValue { return w.path }
        if let s = w.share, let url = URL(string: s) {
            let root = try mountShare(url)
            let sub = w.shareSubpath ?? ""
            let source = sub.isEmpty ? root : root + "/" + sub
            if FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue { return source }
            throw MountError(message: loc("The folder “\(w.name)” was not found on the NAS share \(url.host ?? "")\(url.path). It may have been moved or renamed."))
        }
        throw MountError(message: missingFolderMessage(w.path, connected: { FileManager.default.fileExists(atPath: $0) }))
    }

    /// Laufwerk fehlt oder Ordner wurde verschoben?
    static func missingFolderMessage(_ path: String, connected: (String) -> Bool) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes", !connected("/Volumes/\(parts[1])") {
            return loc("The drive “\(String(parts[1]))” is not connected. Connect it and try again.")
        }
        let name = parts.last.map(String.init) ?? path
        return loc("The folder “\(name)” no longer exists. It may have been moved or renamed: \(path)")
    }

    /// `interactive: false`: ohne jeden Dialog (Passwort nur aus dem Schlüsselbund) – für Wiederverbinden im Hintergrund.
    static func mountShare(_ url: URL, interactive: Bool = true) throws -> String {
        if let path = mountedShare(url) { return path }
        var points: Unmanaged<CFArray>?
        // kNAUIOptionKey / kNAUIOptionNoUI aus NetFS.h (CFSTR-Makros, in Swift nicht verfügbar)
        let ui = interactive ? nil : ["UIOption": "NoUI"] as CFDictionary
        let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, ui.map { NSMutableDictionary(dictionary: $0 as NSDictionary) }, nil, &points)
        // Mehrere Workspaces derselben Freigabe starten gleichzeitig; dann hat ein anderer sie schon eingehängt.
        guard status == 0, let path = (points?.takeRetainedValue() as? [String])?.first ?? mountedShare(url) else {
            if let path = mountedShare(url) { return path }
            throw MountError(message: netfsMessage(status, host: url.host ?? url.absoluteString, share: url.path))
        }
        return path
    }

    /// Fehlercodes beim Verbinden mit einem NAS (NetFS liefert errno-Werte oder OSStatus)
    static func netfsMessage(_ status: Int32, host: String, share: String) -> String {
        switch status {
        case ECANCELED, -128:
            return loc("Connecting to “\(host)” was cancelled.")
        case EAUTH, EACCES, EPERM:
            return loc("The NAS “\(host)” rejected the login. Check user name and password – Mountpoint uses the ones saved in the Keychain.")
        case ENOENT:
            return loc("The share “\(share)” does not exist on “\(host)”.")
        case EHOSTUNREACH, ETIMEDOUT, ENETUNREACH, ECONNREFUSED, EHOSTDOWN, ENETDOWN:
            return loc("The NAS “\(host)” cannot be reached. Check the network connection and whether the NAS is switched on.")
        default:
            return loc("Could not connect to “\(host)” (error \(String(status))).")
        }
    }

    static func mountedShare(_ url: URL) -> String? {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        return FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [])?.first { v in
            (try? v.resourceValues(forKeys: Set(keys)).volumeURLForRemounting).flatMap { $0 }.map { sameShare($0, url) } ?? false
        }?.path
    }
}

/// libfuse trennt Optionen an Kommas; ein Komma im Namen muss maskiert werden.
func fuseEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
}
