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
        didSet { UserDefaults.standard.set(network, forKey: "network") }
    }
    /// Auf allen Netzlaufwerken mit „Avid MediaFiles“ vor Ordnern wie „1“ warnen: dort arbeitet jemand ohne Bin Locking
    @Published var watchNetwork = UserDefaults.standard.bool(forKey: "watchNetwork") {
        didSet { UserDefaults.standard.set(watchNetwork, forKey: "watchNetwork"); notifyGuard() }
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
                notice = String(localized: "Your workspace list could not be read and was set aside as “\(backup.lastPathComponent)” (in ~/Library/Application Support/Mountpoint). Mountpoint started with an empty list.")
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
        // Warnt das ganze Projekt, warnt auch der neue Workspace
        if let project, projectWarns(project) { w.warnNumbered = true }
        library.workspaces.append(w)
        save()
    }

    func remove(_ w: Workspace) {
        if mounted.contains(w.id) {
            do { try Mounter.unmount(w) } catch { errors[w.id] = error.localizedDescription; return }
        }
        library.workspaces.removeAll { $0.id == w.id }
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
            errors[w.id] = String(localized: "Mountpoint is incomplete (its helper program is missing). Please reinstall Mountpoint.")
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
                self.busy.remove(w.id)
                self.errors[w.id] = message
                self.refresh()
            }
        }
    }

    /// Fehlermeldungen wegklicken (eines Workspaces oder aller Workspaces eines Projekts)
    func clearError(_ w: Workspace) { errors[w.id] = nil }
    func clearErrors(in project: UUID?) { workspaces(in: project).forEach(clearError) }

    func unmount(_ w: Workspace) {
        do { try Mounter.unmount(w); errors[w.id] = nil } catch { errors[w.id] = error.localizedDescription }
        refresh()
    }

    // MARK: Warnung bei nummerierten Ordnern

    func toggleWarn(_ w: Workspace) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == w.id }) else { return }
        library.workspaces[i].warnNumbered = !(library.workspaces[i].warnNumbered ?? false)
        save()
        notifyGuard()
    }

    /// Projekt gilt als „an“, wenn alle seine Workspaces warnen.
    func projectWarns(_ project: UUID) -> Bool {
        let items = workspaces(in: project)
        return !items.isEmpty && items.allSatisfy { $0.warnNumbered == true }
    }

    func toggleProjectWarn(_ project: UUID) {
        let on = !projectWarns(project)
        for i in library.workspaces.indices where library.workspaces[i].project == project {
            library.workspaces[i].warnNumbered = on
        }
        save()
        notifyGuard()
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
        save()
        VolumeGuard.shared.refresh()
    }

    func removeGuard(_ name: String) {
        library.guarded.removeAll { $0 == name }
        library.guardOwn.removeAll { $0 == name }
        save()
        VolumeGuard.shared.refresh()
    }

    /// „Avid MediaFiles“ (aus) oder nur der eigene Ordner in MXF (an)
    func setGuardOwn(_ name: String, _ on: Bool) {
        library.guardOwn.removeAll { $0 == name }
        if on { library.guardOwn.append(name) }
        save()
        VolumeGuard.shared.refresh()
    }

    /// Volumes, die man schützen kann: das Systemvolume und eingehängte Volumes (ohne eigene Spiegel-Volumes)
    func guardCandidates() -> [String] {
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path.hasPrefix("/Volumes/") && !Mounter.isMounted($0.path) }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ([systemGuard] + volumes).filter { !library.guarded.contains($0) }
    }

    /// MXF-Ordner, in denen neue Ordner eines Musters warnen
    func folderWatches() -> [FolderWatch] {
        var watches = library.workspaces.filter { $0.warnNumbered == true && mounted.contains($0.id) }.map(FolderWatch.init(workspace:))
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ""
        for name in library.guarded where library.guardOwn.contains(name) {
            let root = guardRoot(name)
            guard name == systemGuard || isMountPoint(root) else { continue }
            let local = name == systemGuard || isLocal(root)
            watches.append(FolderWatch(key: "g:" + name, name: guardName(name), mxf: root + "/Avid MediaFiles/MXF", kind: .own,
                                       matches: local ? isNumberedFolder : { isOwnFolder($0, computer: computer) }))
        }
        if watchNetwork {
            let taken = Set(watches.filter { $0.kind == .workspace }.map(\.mxf))
            for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: [.skipHiddenVolumes]) ?? [] {
                let mxf = url.path + "/Avid MediaFiles/MXF"
                guard url.path.hasPrefix("/Volumes/"), !isLocal(url.path), !taken.contains(mxf),
                      FileManager.default.fileExists(atPath: url.path + "/Avid MediaFiles") else { continue }
                watches.append(FolderWatch(key: "net:" + url.path, name: url.lastPathComponent, mxf: mxf, kind: .network, matches: isNumberedFolder))
            }
        }
        return watches
    }

    private func isLocal(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
    }

    private func isMountPoint(_ path: String) -> Bool {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return false }
        return withUnsafeBytes(of: s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } == path
    }

    // MARK: Einstellungen

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            notice = nil
        } catch {
            notice = on
                ? String(localized: "Launch at login could not be turned on. Move Mountpoint to the Applications folder and try again.") + "\n" + String(localized: "Details: \(error.localizedDescription)")
                : String(localized: "Launch at login could not be turned off. Remove Mountpoint under System Settings → General → Login Items.")
        }
        if on && SMAppService.mainApp.status == .requiresApproval {
            notice = String(localized: "macOS asks you to approve Mountpoint: System Settings → General → Login Items.")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var language: String { UserDefaults.standard.string(forKey: "language") ?? "en" }

    /// Texte werden beim Start geladen, darum startet die App für den Wechsel neu (Volumes bleiben eingehängt).
    func setLanguage(_ code: String) {
        guard code != language else { return }
        UserDefaults.standard.set(code, forKey: "language")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do { try p.run() } catch {
            // ohne Neustart nicht beenden – sonst wäre die App einfach weg
            notice = String(localized: "The language changes the next time Mountpoint starts. Please quit and reopen it.")
            return
        }
        AppDelegate.relaunching = true
        NSApp.terminate(nil)
    }

    func applyAppearance() {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    // MARK: intern

    func refresh() {
        let now = Set(library.workspaces.filter { Mounter.isMounted($0.volumePath) }.map(\.id))
        if now != mounted {
            mounted = now
            notifyGuard()   // eingehängte Workspaces beobachten bzw. nicht mehr
        }
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
            notice = String(localized: "Your changes could not be saved. Check the free space on your Mac.") + "\n" + String(localized: "Details: \(error.localizedDescription)")
        }
    }
}
