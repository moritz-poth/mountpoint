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
    /// Volume-Namen, auf denen kein „Avid MediaFiles“ entstehen soll (z. B. LucidLink); `systemGuard` = Systemvolume
    var guarded: [String] = []
    /// geschützte Volumes, bei denen nur der eigene Ordner in MXF warnt („1“ lokal, „<Rechnername>.1“ im Netz)
    var guardOwn: [String] = []

    /// Nur der eigene Ordner zählt. Immer beim Systemvolume: dort legt die Avid-Installation „Avid MediaFiles“ an.
    func watchesOwn(_ name: String) -> Bool { name == systemGuard || guardOwn.contains(name) }

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
        guardOwn = try c.decodeIfPresent([String].self, forKey: .guardOwn) ?? []
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

/// Ordner, den Media Composer auf einem Netzlaufwerk für diesen Rechner anlegt: "<Rechnername>.1"
func isOwnFolder(_ name: String, computer: String) -> Bool {
    !computer.isEmpty && name.lowercased() == computer.lowercased() + ".1"
}

/// Eintrag in `Library.guarded` für das Systemvolume: dort liegt „Avid MediaFiles“ nicht in der obersten Ebene.
let systemGuard = "/"

/// Ordner, in dem „Avid MediaFiles“ entstehen würde
func guardRoot(_ name: String) -> String {
    name == systemGuard ? "/Users/Shared/AvidMediaComposer" : "/Volumes/" + name
}

/// Anzeigename, beim Systemvolume sein Name im Finder (z. B. „Macintosh HD“)
func guardName(_ name: String) -> String {
    guard name == systemGuard else { return name }
    return (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
}
