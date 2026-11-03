import Foundation

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var mountAtLaunch = false
}

/// Ein Ordner, der als eigenes Volume `/Volumes/<Ordnername>` eingehängt wird.
struct Workspace: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Ordner, wie er beim Hinzufügen gewählt wurde
    var path: String
    var project: UUID?
    /// Netzfreigabe (z. B. smb://nas/Archiv), falls der Ordner auf einem NAS liegt – damit Mountpoint sie selbst einhängen kann
    var share: String?
    /// Pfad innerhalb der Freigabe ("" = Freigabe selbst)
    var shareSubpath: String?
    /// Warnen, wenn in MXF ein Ordner nur aus Ziffern entsteht ("1", "2" …) – die schreibt im Team jedes System.
    /// Optional, damit ältere Dateien ohne das Feld weiter laden.
    var warnNumbered: Bool?

    var name: String { (path as NSString).lastPathComponent }
    var volumePath: String { "/Volumes/" + name }

    init(path: String, project: UUID? = nil, share: String? = nil, shareSubpath: String? = nil) {
        self.path = path
        self.project = project
        self.share = share
        self.shareSubpath = shareSubpath
    }

    /// Merkt sich bei Ordnern auf Netzlaufwerken die Freigabe, damit sie später ohne Finder eingehängt werden kann.
    static func make(url: URL) -> Workspace {
        var w = Workspace(path: url.path)
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeIsLocalKey, .volumeURLForRemountingKey]
        if let v = try? url.resourceValues(forKeys: keys), v.volumeIsLocal == false,
           let remount = v.volumeURLForRemounting, let root = v.volume {
            w.share = remount.absoluteString
            w.shareSubpath = relative(url.path, to: root.path)
        }
        return w
    }
}

struct Library: Codable {
    var projects: [Project] = []
    var workspaces: [Workspace] = []
    /// Volume-Namen, auf denen kein „Avid MediaFiles“ entstehen soll (z. B. LucidLink)
    var guarded: [String] = []

    init(projects: [Project] = [], workspaces: [Workspace] = [], guarded: [String] = []) {
        self.projects = projects
        self.workspaces = workspaces
        self.guarded = guarded
    }

    // Ältere Dateien ohne neue Felder müssen weiter laden – sonst wären alle Workspaces weg.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        guarded = try c.decodeIfPresent([String].self, forKey: .guarded) ?? []
    }
}

/// Pfad relativ zu `root`, ohne führenden Schrägstrich.
func relative(_ path: String, to root: String) -> String {
    let base = root.hasSuffix("/") ? root : root + "/"
    if path == root || path + "/" == base { return "" }
    return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
}

/// Gleiche Freigabe, egal mit welchem Benutzernamen sie eingehängt wurde.
func sameShare(_ a: URL, _ b: URL) -> Bool {
    func norm(_ u: URL) -> String {
        let path = u.path.hasSuffix("/") ? String(u.path.dropLast()) : u.path
        return "\(u.scheme ?? "")://\(u.host ?? "")\(path)".lowercased()
    }
    return norm(a) == norm(b)
}

/// Legt `Avid MediaFiles/MXF` an. Vorhandenes bleibt unberührt.
func createAvidFolders(in folder: URL) throws {
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("Avid MediaFiles/MXF"), withIntermediateDirectories: true)
}

/// Verfügbare Sprachen. Neue Sprache: Resources/<code>.lproj/Localizable.strings anlegen, hier eintragen,
/// und den Code in CFBundleLocalizations (scripts/build-app.sh) ergänzen.
let languages: [(code: String, name: String)] = [("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español")]

/// Ende einer Alarm-Pause; „Rest des Tages“ = nächste Mitternacht.
func snoozeEnd(_ choice: Snooze, from now: Date = Date(), calendar: Calendar = .current) -> Date {
    switch choice {
    case .minutes(let m): return now.addingTimeInterval(TimeInterval(m * 60))
    // über den Kalender, damit Zeitumstellungstage stimmen
    case .restOfDay: return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
    }
}

enum Snooze: Hashable {
    case minutes(Int)
    case restOfDay
    static let all: [Snooze] = [5, 10, 15, 30, 60, 120, 180, 240].map { .minutes($0) } + [.restOfDay]
}

/// Ordnername nur aus Ziffern, z. B. "1" oder "12" (nicht "Mac Studio.1")
func isNumberedFolder(_ name: String) -> Bool {
    !name.isEmpty && name.allSatisfy { $0.isASCII && $0.isNumber }
}
