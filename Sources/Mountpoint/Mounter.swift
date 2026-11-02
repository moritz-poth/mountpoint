import Foundation
import NetFS

struct MountError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Einhängen und Auswerfen. Läuft im Hintergrund (blockierende Aufrufe), darum ohne Zustand.
enum Mounter {
    static let macFUSE = "/Library/Filesystems/macfuse.fs"

    static func isMounted(_ path: String) -> Bool {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return false }
        let on = withUnsafeBytes(of: s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let type = withUnsafeBytes(of: s.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return on == path && type.hasPrefix("macfuse")
    }

    /// `network`: ohne das macFUSE-Flag `local` meldet macOS das Volume als Netzlaufwerk; Media Composer Enterprise
    /// legt dann wie auf geteiltem Speicher einen Ordner "<Rechnername>.1" statt "1" an (getestet mit MC 2026.8).
    static func mount(_ w: Workspace, helper: String, network: Bool = true) throws {
        if isMounted(w.volumePath) { return }
        guard FileManager.default.fileExists(atPath: macFUSE) else {
            throw MountError(message: String(localized: "macFUSE is not installed."))
        }
        let source = try resolveSource(w)
        // Ein leerer Ordner ohne Mount ist nur ein Rest (z. B. nach einem Absturz); darüber darf eingehängt werden.
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: w.volumePath))?.isEmpty == true
        if FileManager.default.fileExists(atPath: w.volumePath) && !leftover {
            throw MountError(message: String(localized: "A volume named “\(w.name)” already exists."))
        }

        // Der Helfer kehrt zurück, sobald das Volume steht, und läuft dann im Hintergrund weiter.
        let (status, msg) = try run(helper, [source, w.volumePath, "-o", "volname=\(fuseEscape(w.name))" + (network ? "" : ",local")])
        guard status == 0, isMounted(w.volumePath) else {
            throw MountError(message: msg.isEmpty ? String(localized: "“\(w.name)” could not be mounted.") : msg)
        }
    }

    /// Nie mit Gewalt auswerfen: hat Avid noch Dateien offen, bleibt das Volume eingehängt.
    static func unmount(_ w: Workspace) throws {
        guard isMounted(w.volumePath) else { return }
        // /sbin/umount statt unmount(2): nur so entfernt macOS danach den leeren Ordner in /Volumes
        let (status, msg) = try run("/sbin/umount", [w.volumePath])
        guard status == 0 else {
            throw MountError(message: msg.localizedCaseInsensitiveContains("busy")
                ? String(localized: "“\(w.name)” is in use. Quit Media Composer and try again.") : msg)
        }
    }

    static func run(_ exe: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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
        }
        throw MountError(message: String(localized: "Folder not found: \(w.path)"))
    }

    static func mountShare(_ url: URL) throws -> String {
        if let path = mountedShare(url) { return path }
        var points: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, nil, nil, &points)
        // Mehrere Workspaces derselben Freigabe starten gleichzeitig; dann hat ein anderer sie schon eingehängt.
        guard status == 0, let path = (points?.takeRetainedValue() as? [String])?.first ?? mountedShare(url) else {
            if let path = mountedShare(url) { return path }
            throw MountError(message: String(localized: "Could not connect to \(url.host ?? url.absoluteString) (error \(String(status)))."))
        }
        return path
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
