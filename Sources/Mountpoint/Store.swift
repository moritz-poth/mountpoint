import AppKit
import ServiceManagement

enum MountState { case none, partial, busy, all }

/// Zustand der App: Projekte, Workspaces, was gerade eingehängt ist.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var library = Library()
    @Published private(set) var mounted: Set<UUID> = []
    @Published private(set) var busy: Set<UUID> = []
    @Published var errors: [UUID: String] = [:]
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
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
        if let data = try? Data(contentsOf: file), let lib = try? JSONDecoder().decode(Library.self, from: data) {
            library = lib
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
            errors[w.id] = "mirror helper missing"
            return
        }
        busy.insert(w.id)
        errors[w.id] = nil
        Task.detached {
            let message: String?
            do { try Mounter.mount(w, helper: helper); message = nil } catch { message = error.localizedDescription }
            await MainActor.run {
                self.busy.remove(w.id)
                self.errors[w.id] = message
                self.refresh()
            }
        }
    }

    func unmount(_ w: Workspace) {
        do { try Mounter.unmount(w); errors[w.id] = nil } catch { errors[w.id] = error.localizedDescription }
        refresh()
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
    }

    /// Beim Beenden auswerfen, was sich auswerfen lässt (nie mit Gewalt).
    func unmountAllOnQuit() {
        for w in library.workspaces where mounted.contains(w.id) { try? Mounter.unmount(w) }
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
        save()
        VolumeGuard.shared.refresh()
    }

    /// Eingehängte Volumes, die man schützen kann (ohne Systemvolume und eigene Spiegel-Volumes)
    func guardCandidates() -> [String] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path.hasPrefix("/Volumes/") && !Mounter.isMounted($0.path) }
            .map(\.lastPathComponent)
            .filter { !library.guarded.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Einstellungen

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert(String(localized: "Launch at login could not be changed."), error.localizedDescription)
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
        try? p.run()
        AppDelegate.relaunching = true
        NSApp.terminate(nil)
    }

    func applyAppearance() {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    // MARK: intern

    func refresh() {
        let now = Set(library.workspaces.filter { Mounter.isMounted($0.volumePath) }.map(\.id))
        if now != mounted { mounted = now }
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
            alert(String(localized: "Workspaces could not be saved."), error.localizedDescription)
        }
    }
}

// MARK: Dialoge

@MainActor
func alert(_ title: String, _ info: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.icon = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
    a.messageText = title
    a.informativeText = info
    a.runModal()
}

