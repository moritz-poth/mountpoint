import AppKit
import ServiceManagement
import SystemConfiguration

enum MountState { case none, partial, busy, all }

/// Zustand der App: Projekte, Workspaces, was gerade eingehängt ist.
@MainActor
final class Store: ObservableObject {
    static let shared: Store = {
        let s = Store()
        s.isShared = true
        return s
    }()
    /// nur die App-Instanz steuert den Wächter (Tests nutzen eigene Stores)
    private var isShared = false

    @Published private(set) var library = Library()
    @Published private(set) var mounted: Set<UUID> = []
    @Published private(set) var busy: Set<UUID> = []
    @Published var errors: [UUID: String] = [:]
    /// Hinweis oben im Panel (statt Systemdialog, der das Panel schließen würde)
    @Published var notice: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Als Netzlaufwerk einbinden (Standard): Avid-Zusammenarbeit mit "<Rechnername>.1"-Ordnern
    @Published var network = UserDefaults.standard.object(forKey: "network") as? Bool ?? true {
        didSet { UserDefaults.standard.set(network, forKey: "network"); Log.write("setting: mount as network drive \(network ? "on" : "off")") }
    }
    /// Auf allen Netzlaufwerken mit „Avid MediaFiles“ vor Ordnern wie „1“ warnen: dort arbeitet jemand ohne Bin Locking
    @Published var watchNetwork = UserDefaults.standard.bool(forKey: "watchNetwork") {
        didSet { UserDefaults.standard.set(watchNetwork, forKey: "watchNetwork"); Log.write("setting: warn about “1” on network drives \(watchNetwork ? "on" : "off")"); notifyGuard() }
    }
    /// MXF-Unterordner mit mehr als 5000 Dateien melden (alle Laufwerke, Systemplatte, Workspaces)
    @Published var watchSize = UserDefaults.standard.bool(forKey: "watchSize") {
        didSet { UserDefaults.standard.set(watchSize, forKey: "watchSize"); Log.write("setting: warn about MXF folders over 5000 files \(watchSize ? "on" : "off")"); notifyGuard() }
    }
    /// Eingehängte Workspaces in der Finder-Seitenleiste unter „Orte“ zeigen (Sidebar.swift)
    @Published var sidebar = UserDefaults.standard.object(forKey: "sidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebar, forKey: "sidebar"); Log.write("setting: Finder sidebar \(sidebar ? "on" : "off")"); syncSidebar() }
    }
    @Published var dark = UserDefaults.standard.object(forKey: "dark") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dark, forKey: "dark"); applyAppearance() }
    }

    /// Ordnerauswahl beginnt hier (Ebene des zuletzt gewählten Ordners)
    var lastFolder: URL? {
        get { UserDefaults.standard.url(forKey: "lastFolder") }
        set { UserDefaults.standard.set(newValue, forKey: "lastFolder") }
    }

    private let file: URL
    private var timer: Timer?

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mountpoint")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: file) {
            do {
                library = try JSONDecoder().decode(Library.self, from: data)
            } catch {
                // Nie stumm mit leerer Liste weitermachen: sonst überschreibt das nächste Speichern die Datei.
                let backup = dir.appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: file, to: backup)
                Log.write("library.json unreadable, set aside as \(backup.lastPathComponent): \(error)")
                notice = loc("Your workspace list could not be read and was set aside as “\(backup.lastPathComponent)” (in ~/Library/Application Support/Mountpoint). Mountpoint started with an empty list.")
            }
        }
        refresh()
        // Volumes können auch im Finder ausgeworfen werden
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Abfragen

    func workspaces(in project: UUID?) -> [Workspace] {
        let known = Set(library.projects.map(\.id))
        return library.workspaces.filter { w in
            project == nil ? w.project.map { !known.contains($0) } ?? true : w.project == project
        }
    }

    // MARK: Workspaces

    func add(_ url: URL, to project: UUID?) {
        var w = Workspace.make(url: url)
        w.project = project
        library.workspaces.append(w)
        Log.write("workspace added: \(w.path)" + (w.share.map { " (share \($0))" } ?? ""))
        save()
    }

    func remove(_ w: Workspace) {
        reconnect[w.id] = nil
        if mounted.contains(w.id) {
            do { try Mounter.unmount(w) } catch { errors[w.id] = error.localizedDescription; return }
        }
        library.workspaces.removeAll { $0.id == w.id }
        Log.write("workspace removed: \(w.path)")
        errors[w.id] = nil
        save()
        refresh()
    }

    func move(_ w: Workspace, to project: UUID?) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == w.id }) else { return }
        library.workspaces[i].project = project
        save()
    }

    func mount(_ w: Workspace) {
        guard !busy.contains(w.id) else { return }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "mirror")?.path else {
            errors[w.id] = loc("Mountpoint is incomplete (its helper program is missing). Please reinstall Mountpoint.")
            return
        }
        busy.insert(w.id)
        errors[w.id] = nil
        let network = self.network
        let icon = Bundle.main.path(forResource: "VolumeIcon", ofType: "icns")
        Task.detached {
            let message: String?
            do { try Mounter.mount(w, helper: helper, network: network, icon: icon); message = nil } catch { message = error.localizedDescription }
            await MainActor.run {
                Log.write(message.map { "mount failed: \(w.path) – \($0)" } ?? "mounted: \(w.path) → \(w.volumePath)" + (network ? "" : " (local)"))
                self.busy.remove(w.id)
                self.errors[w.id] = message
                self.refresh()
            }
        }
    }

    /// Fehlermeldungen wegklicken (eines Workspaces oder aller Workspaces eines Projekts)
    func clearError(_ w: Workspace) { errors[w.id] = nil }
    func clearErrors(in project: UUID?) { workspaces(in: project).forEach(clearError) }

    /// Im Hintergrund wie das Einhängen: hängt das Laufwerk dahinter, wartet umount – die App nicht.
    func unmount(_ w: Workspace) {
        reconnect[w.id] = nil
        guard !busy.contains(w.id) else { return }
        busy.insert(w.id)
        Task.detached {
            // eine laufende Statusprüfung erst fertig werden lassen: kein Zugriff mitten ins Auswerfen
            for _ in 0..<50 where await MainActor.run(body: { self.probing[w.id] != nil }) { try? await Task.sleep(nanoseconds: 100_000_000) }
            let message: String?
            do { try Mounter.unmount(w); message = nil } catch { message = error.localizedDescription }
            await MainActor.run {
                Log.write(message.map { "eject failed: \(w.volumePath) – \($0)" } ?? "ejected: \(w.volumePath)")
                self.busy.remove(w.id)
                self.errors[w.id] = message
                self.refresh()
            }
        }
    }

    private func syncSidebar() {
        guard isShared else { return }   // Tests fassen die echte Seitenleiste nie an
        Sidebar.sync(sidebar ? Set(library.workspaces.filter { mounted.contains($0.id) }.map(\.volumePath)) : [])
    }

    private func notifyGuard() {
        if isShared { VolumeGuard.shared.refresh() }
    }

    // MARK: Projekte

    func addProject(_ name: String) {
        library.projects.append(Project(name: name))
        save()
    }

    func rename(_ p: Project, to name: String) {
        update(p) { $0.name = name }
    }

    func toggleMountAtLaunch(_ p: Project) {
        update(p) { $0.mountAtLaunch.toggle() }
    }

    /// Löscht das Projekt. Workspaces werden entfernt (nur Eintrag + Auswerfen) oder wandern zu „Ohne Projekt“.
    /// Lässt sich ein Volume nicht auswerfen, bleibt sein Workspace erhalten und zeigt den Fehler.
    func delete(_ p: Project, removeWorkspaces: Bool) {
        Log.write("project deleted: \(p.name)" + (removeWorkspaces ? " (with its workspaces)" : ""))
        library.projects.removeAll { $0.id == p.id }
        for w in library.workspaces where w.project == p.id {
            if removeWorkspaces { remove(w) }
        }
        for i in library.workspaces.indices where library.workspaces[i].project == p.id {
            library.workspaces[i].project = nil
        }
        save()
    }

    /// Sammelstatus für den Punkt vor einem Projekt
    func state(of project: UUID?) -> MountState {
        let items = workspaces(in: project)
        if items.contains(where: { busy.contains($0.id) }) { return .busy }
        let up = items.filter { mounted.contains($0.id) }.count
        if items.isEmpty || (up == 0 && !items.contains { errors[$0.id] != nil }) { return .none }
        return up == items.count && !items.contains { errors[$0.id] != nil } ? .all : .partial
    }

    func mountAll(_ project: UUID?) { workspaces(in: project).forEach(mount) }
    func unmountAll(_ project: UUID?) { workspaces(in: project).filter { mounted.contains($0.id) }.forEach(unmount) }

    func mountAtLaunch() {
        for p in library.projects where p.mountAtLaunch { mountAll(p.id) }
        // after an update: mount again what was mounted before
        let again = Set((UserDefaults.standard.stringArray(forKey: "remountAfterUpdate") ?? []).compactMap(UUID.init))
        UserDefaults.standard.removeObject(forKey: "remountAfterUpdate")
        for w in library.workspaces where again.contains(w.id) && !mounted.contains(w.id) { mount(w) }
    }

    func rememberMountedForUpdate() {
        UserDefaults.standard.set(mounted.map(\.uuidString), forKey: "remountAfterUpdate")
    }

    /// Beim Beenden auswerfen, was sich auswerfen lässt (nie mit Gewalt). Gibt die Namen zurück, die eingehängt bleiben.
    func unmountAllOnQuit() -> [String] {
        var still: [String] = []
        for w in library.workspaces where mounted.contains(w.id) {
            do { try Mounter.unmount(w) } catch { still.append(w.name) }
        }
        return still
    }

    // MARK: Geschützte Volumes

    func addGuard(_ name: String) {
        guard !library.guarded.contains(name) else { return }
        library.guarded.append(name)
        Log.write("protected volume added: \(guardRoot(name))")
        save()
        notifyGuard()
    }

    func removeGuard(_ name: String) {
        library.guarded.removeAll { $0 == name }
        library.guardOwn.removeAll { $0 == name }
        Log.write("protected volume removed: \(guardRoot(name))")
        save()
        notifyGuard()
    }

    /// „Avid MediaFiles“ (aus) oder nur der eigene Ordner in MXF (an)
    func setGuardOwn(_ name: String, _ on: Bool) {
        library.guardOwn.removeAll { $0 == name }
        if on { library.guardOwn.append(name) }
        Log.write("protected volume \(guardRoot(name)) watches: \(on ? "workstation folder" : "Avid MediaFiles")")
        save()
        notifyGuard()
    }

    /// Volumes, die man schützen kann: das Systemvolume und eingehängte Volumes (ohne eigene Spiegel-Volumes)
    func guardCandidates() -> [String] {
        let volumes = Mounter.mounts()
            .filter { $0.point.hasPrefix("/Volumes/") && !$0.hidden && !$0.own }
            .map { guardEntry($0.point) }
            .sorted { guardName($0).localizedStandardCompare(guardName($1)) == .orderedAscending }
        return ([systemGuard] + volumes).filter { !library.guarded.contains($0) }
    }

    /// Orte, deren MXF-Unterordner gezählt werden; leer, wenn ausgeschaltet. Eigene Spiegel-Volumes nicht – ihre Quelle zählt schon.
    func sizeRoots() -> [SizeRoot] {
        guard watchSize else { return [] }
        var roots = [SizeRoot(name: guardName(systemGuard), root: guardRoot(systemGuard))]
        roots += Mounter.mounts().filter { $0.point.hasPrefix("/Volumes/") && !$0.hidden && !$0.own }
            .map { SizeRoot(name: ($0.point as NSString).lastPathComponent, root: $0.point) }
        roots += library.workspaces.map { SizeRoot(name: $0.name, root: $0.path) }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.root).inserted }
    }

    /// MXF-Ordner, in denen neue Ordner eines Musters warnen
    func folderWatches() -> [FolderWatch] {
        var watches: [FolderWatch] = []
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ""
        let table = Mounter.mounts()
        for name in library.guarded where library.watchesOwn(name) {
            let root = guardRoot(name)
            let mount = table.first { $0.point == root }
            guard name == systemGuard || mount != nil else { continue }
            let local = name == systemGuard || mount?.local == true
            watches.append(FolderWatch(key: "g:" + name, name: guardName(name), mxf: root + "/Avid MediaFiles/MXF", kind: .own,
                                       matches: local ? { $0 == "1" } : { isOwnFolder($0, computer: computer) }))
        }
        if watchNetwork {
            // ob dort „Avid MediaFiles/MXF“ liegt, prüft der Wächter im Hintergrund
            // eigene Spiegel-Volumes nicht direkt (Zugriffe beim Auswerfen über macFUSE), sondern ihren Quellordner auf dem NAS
            for m in table where m.point.hasPrefix("/Volumes/") && !m.local && !m.hidden && !m.own {
                watches.append(FolderWatch(key: "net:" + m.point, name: (m.point as NSString).lastPathComponent,
                                           mxf: m.point + "/Avid MediaFiles/MXF", kind: .network, matches: { $0 == "1" }))
            }
            for w in library.workspaces where table.contains(where: { m in !m.own && !m.local && w.path.hasPrefix(m.point + "/") }) {
                watches.append(FolderWatch(key: "net:" + w.path, name: w.name, mxf: w.path + "/Avid MediaFiles/MXF", kind: .network, matches: { $0 == "1" }))
            }
        }
        return watches
    }


    // MARK: Einstellungen

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            notice = nil
        } catch {
            notice = on
                ? loc("Launch at login could not be turned on. Move Mountpoint to the Applications folder and try again.") + "\n" + loc("Details: \(error.localizedDescription)")
                : loc("Launch at login could not be turned off. Remove Mountpoint under System Settings → General → Login Items.")
        }
        if on && SMAppService.mainApp.status == .requiresApproval {
            notice = loc("macOS asks you to approve Mountpoint: System Settings → General → Login Items.")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    @Published private(set) var language = UserDefaults.standard.string(forKey: "language") ?? "en"
    var locale: Locale { Locale(identifier: language) }

    /// Sofort: SwiftUI-Texte folgen `locale`, `loc()` dem Bundle. Schon angezeigte Meldungen bleiben in der alten Sprache.
    func setLanguage(_ code: String) {
        guard code != language else { return }
        UserDefaults.standard.set(code, forKey: "language")
        UserDefaults.standard.set([code], forKey: "AppleLanguages")   // Systemtexte (z. B. Beenden-Dialog) ab dem nächsten Start
        languageBundle = bundle(for: code)
        language = code
        Log.write("language: \(code)")
    }

    func applyAppearance() {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    // MARK: intern

    func refresh() {
        let table = Mounter.mounts()
        let now = Set(library.workspaces.filter { Mounter.isMounted($0, in: table) }.map(\.id))
        if now != mounted {
            mounted = now
            notifyGuard()   // eingehängte Workspaces beobachten bzw. nicht mehr
        }
        syncSidebar()   // auch nach Auswerfen im Finder und nach einem Absturz (erster Refresh räumt auf)
        findDeadHelpers()
        reconnectWhenBack(table)
    }

    /// Nach einem Ausfall ausgeworfene Workspaces (Wert: letzter Versuch). Sie werden wieder eingehängt, sobald das Laufwerk
    /// mit ihrem Ordner wieder in der Mount-Liste steht – Mountpoint verbindet das NAS nicht selbst (macOS-Dialoge mitten im Ausfall).
    private var reconnect: [UUID: Date] = [:]
    /// Freigaben, die gerade im Hintergrund neu verbunden werden (Wert: letzter Versuch)
    private var shareAttempts: [String: Date] = [:]
    private var shareBusy: Set<String> = []

    private func reconnectWhenBack(_ table: [Mounter.Mount]) {
        // shortcut: versucht alle 15 s ohne Obergrenze, solange das Laufwerk da ist, das Einhängen aber scheitert; Grenze erst bei Bedarf
        for (id, last) in reconnect where Date().timeIntervalSince(last) > 15 && !busy.contains(id) {
            guard let w = library.workspaces.first(where: { $0.id == id }) else { reconnect[id] = nil; continue }
            if mounted.contains(id) { reconnect[id] = nil; continue }
            // das Laufwerk, auf dem der Ordner liegt, ist wieder eingehängt (Ordner direkt in /Volumes: nur die Systemplatte)
            let back = table.contains { m in !m.own && m.point != "/" && w.path.hasPrefix(m.point + "/") }
            guard back else {
                if let share = w.share { reconnectShare(share, for: w) }
                continue
            }
            reconnect[id] = Date()
            Log.write("drive is back, mounting again: \(w.path)")
            mount(w)
        }
    }

    /// NAS im Hintergrund neu verbinden – ohne Dialog, alle 30 s, eine Freigabe nur einmal gleichzeitig.
    /// Klappt es, wird der Workspace sofort eingehängt; sonst bleibt alles still (das NAS ist eben noch weg).
    private func reconnectShare(_ share: String, for w: Workspace) {
        guard let url = URL(string: share), !shareBusy.contains(share),
              Date().timeIntervalSince(shareAttempts[share] ?? .distantPast) > 30 else { return }
        shareBusy.insert(share)
        shareAttempts[share] = Date()
        Task.detached {
            let ok = (try? Mounter.mountShare(url, interactive: false)) != nil
            await MainActor.run {
                self.shareBusy.remove(share)
                guard ok, self.reconnect[w.id] != nil, !self.mounted.contains(w.id), !self.busy.contains(w.id) else { return }
                Log.write("NAS connected again: \(url.host ?? share), mounting \(w.path)")
                self.reconnect[w.id] = Date()
                self.mount(w)
            }
        }
    }

    private let probe = DispatchQueue(label: "Mountpoint.probe", attributes: .concurrent)
    /// laufende Prüfungen mit Startzeit; Volumes, die gerade als „reagiert nicht“ angezeigt werden
    private var probing: [UUID: Date] = [:]
    private var slow: Set<UUID> = []
    private var lastOddCode: [UUID: Int32] = [:]

    static func notResponding(_ name: String) -> String {
        loc("“\(name)” is not responding. Check the connection to its drive or NAS – the message goes away as soon as it answers again.")
    }

    /// Ist ein Helfer abgestürzt, bleibt sein Volume tot eingehängt („Device not configured“, ENXIO).
    /// Geprüft wird im Hintergrund: ein hängendes Laufwerk blockiert dort höchstens einen Thread.
    private func findDeadHelpers() {
        // Hängt die Prüfung (NAS weg, aber von macOS noch nicht getrennt): in der Zeile zeigen, statt zu schweigen
        for (id, started) in probing where Date().timeIntervalSince(started) > 10 && !slow.contains(id) && errors[id] == nil {
            guard let w = library.workspaces.first(where: { $0.id == id }) else { continue }
            slow.insert(id)
            errors[id] = Self.notResponding(w.name)
            Log.write("not responding: \(w.volumePath)")
        }
        for w in library.workspaces where mounted.contains(w.id) && !busy.contains(w.id) && probing[w.id] == nil {
            probing[w.id] = Date()
            let path = w.volumePath
            probe.async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                // Die Wurzel kennt der Kernel auch ohne Helfer; ein (nie zwischengespeicherter) Phantasiename fragt den Helfer selbst.
                var st = stat()
                // gesund: ENOENT (den Namen gibt es nicht); ENXIO: Helfer tot; alles andere: Laufwerk dahinter antwortet nicht richtig
                let code = lstat(path + "/.mountpoint-probe-\(UInt32.random(in: 0...UInt32.max))", &st) == -1 ? errno : ENOENT
                DispatchQueue.main.async { MainActor.assumeIsolated { self.probed(w, code: code) } }
            }
        }
    }

    /// Fehler, mit denen ein Netzlaufwerk meldet, dass sein Server weg ist
    static let unreachable: Set<Int32> = [EIO, ETIMEDOUT, ENOTCONN, EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH, ESTALE, ECONNRESET]

    private func probed(_ w: Workspace, code: Int32) {
        probing[w.id] = nil
        let reason = "\(String(cString: strerror(code))) (\(code))"
        if Self.unreachable.contains(code), mounted.contains(w.id) {
            if !slow.contains(w.id), errors[w.id] == nil {
                slow.insert(w.id)
                errors[w.id] = Self.notResponding(w.name)
                Log.write("not responding: \(w.volumePath) – \(reason)")
            }
            return
        }
        // nur Ungewöhnliches, und nicht alle 3 s dasselbe
        if code != ENOENT && code != ENXIO && lastOddCode[w.id] != code { Log.write("check of \(w.volumePath): \(reason)") }
        lastOddCode[w.id] = code == ENOENT ? nil : code
        if slow.remove(w.id) != nil, errors[w.id] == Self.notResponding(w.name) {
            errors[w.id] = nil
            if code != ENXIO { Log.write("responding again: \(w.volumePath)") }
        }
        guard code == ENXIO, mounted.contains(w.id) else { return }
        Log.write("helper stopped: \(w.volumePath)")
        do {
            try Mounter.unmount(w)
            errors[w.id] = loc("“\(w.name)” stopped responding and was ejected. Mountpoint mounts it again as soon as its drive is back.")
            reconnect[w.id] = .distantPast
        } catch {
            errors[w.id] = loc("“\(w.name)” stopped responding. Quit Media Composer and eject it in the Finder, then mount it again.")
        }
        refresh()
    }

    private func update(_ p: Project, _ change: (inout Project) -> Void) {
        guard let i = library.projects.firstIndex(where: { $0.id == p.id }) else { return }
        change(&library.projects[i])
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(library).write(to: file, options: .atomic)
        } catch {
            Log.write("saving library.json failed: \(error)")
            notice = loc("Your changes could not be saved. Check the free space on your Mac.") + "\n" + loc("Details: \(error.localizedDescription)")
        }
    }
}
