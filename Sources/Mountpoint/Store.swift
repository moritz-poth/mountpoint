import AppKit
import ServiceManagement
import SystemConfiguration

enum MountState { case none, partial, busy, all }

/// Zustand der App: Projekte, Workspaces, was gerade eingehängt ist.
@MainActor
final class Store: ObservableObject {
    static let shared: Store = {
        // in der Einstellungs-App passiv: kein Einhängen, kein Wächter, keine Seitenleiste – nur lesen und speichern
        let s = Store(passive: settingsMode)
        s.isShared = true
        return s
    }()
    private var passive = false
    /// nur die App-Instanz steuert den Wächter (Tests nutzen eigene Stores)
    private var isShared = false

    @Published private(set) var library = Library()
    @Published private(set) var mounted: Set<UUID> = []
    @Published private(set) var busy: Set<UUID> = []
    @Published var errors: [UUID: String] = [:]
    /// Hinweis oben im Panel (statt Systemdialog, der das Panel schließen würde)
    @Published var notice: String?
    /// Mountpoint: SMAppService; Einstellungs-App: was Mountpoint zuletzt gemeldet hat (`launchAtLoginState`)
    @Published private(set) var launchAtLogin = false
    /// Als Netzlaufwerk einbinden (Standard): Avid-Zusammenarbeit mit "<Rechnername>.1"-Ordnern
    @Published var network = defaults.object(forKey: "network") as? Bool ?? true {
        didSet { defaults.set(network, forKey: "network"); logSetting("mount as network drive \(network ? "on" : "off")"); announce() }
    }
    /// Auf allen Netzlaufwerken mit „Avid MediaFiles“ vor Ordnern wie „1“ warnen: dort arbeitet jemand ohne Bin Locking
    @Published var watchNetwork = defaults.bool(forKey: "watchNetwork") {
        didSet { defaults.set(watchNetwork, forKey: "watchNetwork"); logSetting("warn about “1” on network drives \(watchNetwork ? "on" : "off")"); notifyGuard(); announce() }
    }
    /// MXF-Unterordner mit mehr als `sizeLimit` Dateien melden (alle Laufwerke, Systemplatte, Workspaces)
    @Published var watchSize = defaults.bool(forKey: "watchSize") {
        didSet { defaults.set(watchSize, forKey: "watchSize"); logSetting("warn about full MXF folders \(watchSize ? "on" : "off")"); notifyGuard(); announce() }
    }
    /// Grenze pro MXF-Unterordner wie in MediaFiles Check (100…50000, Standard 5000): Warnung ab einer Datei mehr, Vorwarnung ab 90 %
    @Published var sizeLimit = Store.validLimit(defaults.integer(forKey: "sizeLimit")) {
        didSet {
            defaults.set(sizeLimit, forKey: "sizeLimit"); logSetting("MXF folder limit \(sizeLimit) files")
            if isShared, !passive { VolumeGuard.shared.sizeLimit = sizeLimit }
            notifyGuard(); announce()
        }
    }
    static let limitRange = 100...50000
    static func validLimit(_ n: Int) -> Int { limitRange.contains(n) ? n : 5000 }
    /// Auch Vorabversionen (Testversionen) als Update anbieten – nur für Tester
    @Published var betas = defaults.bool(forKey: "betas") {
        didSet { defaults.set(betas, forKey: "betas"); logSetting("test versions \(betas ? "on" : "off")"); announce() }
    }
    /// Eingehängte Workspaces in der Finder-Seitenleiste unter „Orte“ zeigen (Sidebar.swift)
    @Published var sidebar = defaults.object(forKey: "sidebar") as? Bool ?? true {
        didSet { defaults.set(sidebar, forKey: "sidebar"); logSetting("Finder sidebar \(sidebar ? "on" : "off")"); syncSidebar(); announce() }
    }
    @Published var dark = defaults.object(forKey: "dark") as? Bool ?? true {
        didSet { defaults.set(dark, forKey: "dark"); logSetting("dark \(dark ? "on" : "off")"); applyAppearance(); announce() }
    }

    /// Ordnerauswahl beginnt hier (Ebene des zuletzt gewählten Ordners)
    var lastFolder: URL? {
        get { defaults.url(forKey: "lastFolder") }
        set { defaults.set(newValue, forKey: "lastFolder") }
    }

    private let file: URL
    private var timer: Timer?
    /// Stand der Datei beim letzten Laden/Speichern: was davon abweicht, hat dieser Prozess geändert (save() führt zusammen)
    private var loaded = Library()
    /// Einstellungs-App mit unlesbarer library.json: nie speichern (sonst ginge die Workspace-Liste verloren)
    private(set) var readOnly = false
    /// Mountpoint: die Liste im Speicher ist maßgeblich (Datei gelesen, oder es gab keine). Falsch nur nach einem Start mit
    /// unlesbarer Datei, die nicht beiseitegelegt werden konnte: dann übernimmt die erste lesbare Fassung die Workspaces
    /// von der Platte, statt sie mit der leeren Liste zu überschreiben.
    private var knowsList = true

    init(directory: URL? = nil, passive: Bool = false) {
        self.passive = passive
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mountpoint")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("library.json")
        switch readDisk() {
        case .ok(let lib):
            library = lib
            loaded = lib
        case .missing:
            break   // erster Start: leere Liste
        case .unreadable(let error) where passive:
            // Einstellungs-App: Datei nie beiseitelegen (das macht Mountpoint) und nichts speichern
            readOnly = true
            Log.write("library.json unreadable in the settings app: \(error)")
            notice = Self.readOnlyText
        case .unreadable(let error):
            // Nie stumm mit leerer Liste weitermachen: beiseitelegen, erst danach neu schreiben (eine offene
            // Einstellungs-App lädt dann die leere Liste). Scheitert das Verschieben, bleibt die Datei unberührt.
            locked {
                if let backup = setAside(error) {
                    do { try JSONEncoder().encode(Library()).write(to: file, options: .atomic) }
                    catch { Log.write("empty library.json could not be written after setting it aside: \(error)") }
                    notice = loc("Your workspace list could not be read and was set aside as “\(backup)” (in ~/Library/Application Support/Mountpoint). Mountpoint started with an empty list.")
                } else {
                    knowsList = false
                    notice = Self.cannotSetAside
                }
            }
        }
        if passive {
            launchAtLogin = defaults.bool(forKey: "launchAtLoginState")
            confirmedLogin = launchAtLogin
            return
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
        guard !passive else { return }   // Einstellungs-App: nie einhängen, auswerfen oder prüfen
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
        guard !passive else { return }   // Einstellungs-App: nie einhängen, auswerfen oder prüfen
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
        guard isShared, !passive else { return }   // Tests fassen die echte Seitenleiste nie an
        Sidebar.sync(sidebar ? Set(library.workspaces.filter { mounted.contains($0.id) }.map(\.volumePath)) : [],
                     names: Set(library.workspaces.map(\.name)))
    }

    private func notifyGuard() {
        if isShared, !passive { VolumeGuard.shared.refresh() }
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
        let again = Set((defaults.stringArray(forKey: "remountAfterUpdate") ?? []).compactMap(UUID.init))
        defaults.removeObject(forKey: "remountAfterUpdate")
        for w in library.workspaces where again.contains(w.id) && !mounted.contains(w.id) { mount(w) }
    }

    func rememberMountedForUpdate() {
        defaults.set(mounted.map(\.uuidString), forKey: "remountAfterUpdate")
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

    /// schreibgeschützt: ablehnen, bevor sich etwas ändert – sonst stünde im Fenster, was nie gespeichert wird
    private func refusedReadOnly() -> Bool {
        if readOnly { notice = Self.readOnlyText }
        return readOnly
    }

    func addGuard(_ name: String) {
        guard !refusedReadOnly(), !library.guarded.contains(name) else { return }
        library.guarded.append(name)
        Log.write("protected volume added: \(guardRoot(name))")
        save()
        notifyGuard()
    }

    func removeGuard(_ name: String) {
        guard !refusedReadOnly() else { return }
        library.guarded.removeAll { $0 == name }
        library.guardOwn.removeAll { $0 == name }
        Log.write("protected volume removed: \(guardRoot(name))")
        save()
        notifyGuard()
    }

    /// „Avid MediaFiles“ (aus) oder nur der eigene Ordner in MXF (an)
    func setGuardOwn(_ name: String, _ on: Bool) {
        guard !refusedReadOnly() else { return }
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

    /// `request`: Auftrag der Einstellungs-App (ihre Kennung geht mit der Antwort zurück; das Panel zeigt dann nichts)
    func setLaunchAtLogin(_ on: Bool, request: String? = nil) {
        // Startobjekt muss Mountpoint selbst eintragen – aus der Einstellungs-App wäre es sonst die Einstellungs-App
        if passive {
            launchAtLogin = on
            clearLoginNotice()
            let id = UUID().uuidString
            pendingLogin?.cancel()
            pendingLoginID = id
            if isShared { IPC.post("launchAtLogin", ["on": on ? "1" : "0", "id": id]) }   // nur die echte Einstellungs-App, nie Tests
            // keine Antwort: zurück auf den zuletzt bestätigten Zustand, sagen warum
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pendingLoginID == id else { return }
                    self.pendingLoginID = nil
                    self.launchAtLogin = self.confirmedLogin
                    self.showLoginNotice(loc("Mountpoint did not answer, so launch at login was not changed. Open Mountpoint and try again."))
                }
            }
            pendingLogin = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
            return
        }
        var problem: String?
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            problem = on
                ? loc("Launch at login could not be turned on. Move Mountpoint to the Applications folder and try again.") + "\n" + loc("Details: \(error.localizedDescription)")
                : loc("Launch at login could not be turned off. Remove Mountpoint under System Settings → General → Login Items.")
        }
        if on && SMAppService.mainApp.status == .requiresApproval {
            problem = loc("macOS asks you to approve Mountpoint: System Settings → General → Login Items.")
        }
        logSetting("launch at login \(on ? "on" : "off")" + (problem == nil ? "" : " – failed"))   // nur Mountpoint protokolliert
        if request == nil { notice = problem }   // Auftrag der Einstellungs-App: sie zeigt den Fehler, nicht das Panel
        // auch der Einstellungs-App antworten (echter Zustand + Fehler, sie zeigt ihn im Fenster)
        publishLaunchAtLogin(error: problem, request: request)
    }

    @Published private(set) var language = defaults.string(forKey: "language") ?? "en"
    var locale: Locale { Locale(identifier: language) }

    /// Sofort: SwiftUI-Texte folgen `locale`, `loc()` dem Bundle. Schon angezeigte Meldungen bleiben in der alten Sprache.
    func setLanguage(_ code: String) {
        guard code != language else { return }
        defaults.set(code, forKey: "language")
        defaults.set([code], forKey: "AppleLanguages")   // Systemtexte (z. B. Beenden-Dialog) ab dem nächsten Start
        if settingsMode { UserDefaults.standard.set([code], forKey: "AppleLanguages") }   // eigene Domäne der Einstellungs-App
        languageBundle = bundle(for: code)
        language = code
        logSetting("language \(code)")
        announce()
    }

    private var pendingLogin: DispatchWorkItem?
    /// Kennung des offenen Auftrags an Mountpoint; nur dessen Antwort darf den Schalter setzen und einen Fehler zeigen
    private(set) var pendingLoginID: String?
    /// zuletzt von Mountpoint bestätigter Zustand (dahin geht der Schalter ohne Antwort zurück)
    private var confirmedLogin = false
    /// zuletzt gezeigter Hinweis zum Startobjekt – nur ihn räumt der Schalter weg, andere Hinweise (z. B. schreibgeschützt) bleiben
    private var loginNotice: String?
    private func showLoginNotice(_ text: String) { loginNotice = text; notice = text }
    /// eigenen Hinweis wegnehmen; war die Liste schreibgeschützt, kommt deren Hinweis zurück (er war nur verdrängt)
    private func clearLoginNotice() {
        guard notice != nil, notice == loginNotice else { return }
        notice = readOnly ? Self.readOnlyText : nil
    }

    /// Mountpoint: Zustand „Beim Anmelden starten“ der Einstellungs-App mitteilen (sie kann SMAppService der App nicht
    /// fragen) – immer mit dem echten Zustand, auch wenn er gleich blieb, und mit der Fehlermeldung, falls es eine gab.
    func publishLaunchAtLogin(error: String? = nil, request: String? = nil) {
        guard isShared, !passive else { return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        defaults.set(launchAtLogin, forKey: "launchAtLoginState")
        IPC.post("launchAtLoginResult", ["on": launchAtLogin ? "1" : "0", "error": error ?? "", "id": request ?? ""])
    }

    /// Einstellungs-App: Antwort von Mountpoint. Antwort auf den offenen Auftrag: Schalter + Fehler; Antwort auf einen
    /// älteren Auftrag: nur merken (der offene läuft noch); sonst (Abfrage, späte Antwort): Schalter folgt, Hinweis weg.
    func launchAtLoginResult(on: Bool, error: String, request: String) {
        confirmedLogin = on
        if let pending = pendingLoginID {
            guard request == pending else { return }
            pendingLogin?.cancel()
            pendingLogin = nil
            pendingLoginID = nil
            launchAtLogin = on
            if !error.isEmpty { showLoginNotice(error) } else { clearLoginNotice() }
            return
        }
        launchAtLogin = on
        clearLoginNotice()
    }

    /// in der Einstellungs-App: Mountpoint Bescheid geben, dass sich Einstellungen geändert haben (nicht beim Neuladen)
    private func announce() { if isShared && passive && !reloading { IPC.post("settings") } }
    /// Änderung protokollieren – nur in dem Prozess, der sie gemacht hat (nicht beim Neuladen im anderen)
    private func logSetting(_ text: String) { if !reloading { Log.write("setting: " + text) } }
    /// reloadSettings weist gerade zu: keine Meldung, keine Logzeile
    private var reloading = false

    /// Einstellungen neu lesen, die das andere Programm geändert hat. Nur Abweichungen zuweisen: die didSet-Wirkungen
    /// (Wächter, Seitenleiste, Aussehen) laufen dann genau einmal.
    func reloadSettings() {
        reloading = true
        defer { reloading = false }
        CFPreferencesAppSynchronize(mainBundleID as CFString)
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        if network != flag("network", true) { network = flag("network", true) }
        if watchNetwork != flag("watchNetwork", false) { watchNetwork = flag("watchNetwork", false) }
        if watchSize != flag("watchSize", false) { watchSize = flag("watchSize", false) }
        let limit = Store.validLimit(defaults.integer(forKey: "sizeLimit"))
        if sizeLimit != limit { sizeLimit = limit }
        if sidebar != flag("sidebar", true) { sidebar = flag("sidebar", true) }
        if dark != flag("dark", true) { dark = flag("dark", true) }
        if betas != flag("betas", false) { betas = flag("betas", false); if !passive { Updater.shared.check(manual: false) } }
        if let code = defaults.string(forKey: "language"), code != language { setLanguage(code) }
    }

    /// library.json neu laden, nachdem das andere Programm sie gespeichert hat (Zusammenführen wie beim Speichern).
    /// Fehlt oder ist sie unlesbar, repariert Mountpoint sie aus seinem Speicher (save); die Einstellungs-App wird
    /// schreibgeschützt und bittet Mountpoint darum.
    func reloadLibrary() {
        let disk: Library
        switch readDisk() {
        case .ok(let lib): disk = lib
        case .missing:
            if passive { if isShared { IPC.post("library") } }   // gelöscht: eine laufende Mountpoint legt sie neu an
            else { save() }
            return
        case .unreadable(let error):
            Log.write("library.json unreadable, not reloaded: \(error)")
            if passive {
                readOnly = true
                notice = Self.readOnlyText
                if isShared { IPC.post("library") }   // eine laufende Mountpoint liest, findet die Datei kaputt und repariert
            } else {
                save()
            }
            return
        }
        library = merged(onto: disk)
        loaded = disk
        knowsList = true
        if readOnly {
            readOnly = false
            if notice == Self.readOnlyText { notice = nil }
        }
        notifyGuard()
        syncSidebar()
        // Datei hat weniger als Mountpoint (z. B. gelöscht und von einer neu gestarteten Einstellungs-App ohne Workspaces
        // angelegt): sofort zurückschreiben – nicht erst bei der nächsten Änderung, die vor dem Beenden vielleicht nie kommt
        if !passive && (disk.projects != library.projects || disk.workspaces != library.workspaces) { save() }
    }

    func applyAppearance() {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    // MARK: intern

    func refresh() {
        guard !passive else { return }   // Einstellungs-App: nie einhängen, auswerfen oder prüfen
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

    static var readOnlyText: String {
        loc("Your workspace list could not be read, so changes to protected volumes cannot be saved right now. Mountpoint repairs the list while it runs – open Mountpoint if it is not running. If this message stays, check the folder ~/Library/Application Support/Mountpoint.")
    }
    static var cannotSetAside: String {
        loc("Your workspace list could not be read and could not be set aside either. Mountpoint does not change it. Check the folder ~/Library/Application Support/Mountpoint.")
    }

    /// Nur Mountpoint, unter der Sperre: unlesbare Datei beiseitelegen. Gibt den neuen Namen zurück; nil = nicht
    /// verschoben, dann darf auch nichts geschrieben werden.
    private func setAside(_ error: Error) -> String? {
        let backup = file.deletingLastPathComponent().appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        do { try FileManager.default.moveItem(at: file, to: backup) } catch let moveError {
            Log.write("library.json unreadable (\(error)) and could not be set aside: \(moveError)")
            return nil
        }
        Log.write("library.json unreadable, set aside as \(backup.lastPathComponent): \(error)")
        return backup.lastPathComponent
    }

    /// Dateisperre beider Programme um Lesen, Zusammenführen und Schreiben
    private func locked<T>(_ work: () -> T) -> T {
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR, 0o644)
        if lock >= 0 { flock(lock, LOCK_EX) } else { Log.write("library.json.lock could not be opened (\(String(cString: strerror(errno)))), working without it") }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        return work()
    }

    private enum Disk { case ok(Library), missing, unreadable(Error) }

    /// „Fehlt“ nur, wenn es die Datei nicht gibt. Jeder andere Fehler (Rechte, Lesefehler, kaputtes JSON) ist „unlesbar“:
    /// dann wird nie geschrieben – sonst ersetzte eine leere oder alte Kopie die Workspace-Liste.
    private func readDisk() -> Disk {
        let data: Data
        do { data = try Data(contentsOf: file) } catch let e as CocoaError where e.code == .fileReadNoSuchFile { return .missing } catch { return .unreadable(error) }
        do { return .ok(try JSONDecoder().decode(Library.self, from: data)) } catch { return .unreadable(error) }
    }

    /// Feldbesitz im Code: Projekte und Workspaces gehören Mountpoint – es nimmt sie immer aus dem Speicher, die
    /// Einstellungs-App immer aus der Datei (eine leere oder alte Kopie von ihr kann sie also nie ersetzen).
    /// Geschützte Volumes: was dieser Prozess seit dem letzten Laden geändert hat, aus dem Speicher, sonst aus `disk`.
    private func merged(onto disk: Library) -> Library {
        var m = disk
        if !passive && knowsList {
            m.projects = library.projects
            m.workspaces = library.workspaces
        }
        if library.guarded != loaded.guarded { m.guarded = library.guarded }
        if library.guardOwn != loaded.guardOwn { m.guardOwn = library.guardOwn }
        return m
    }

    /// Speichert zusammengeführt: Mountpoint und die Einstellungs-App schreiben dieselbe Datei. Unter einer Dateisperre
    /// wird sie neu gelesen; nur die Teile, die dieser Prozess seit dem letzten Laden geändert hat, kommen aus dem
    /// Speicher, alles andere aus der Datei – so überschreibt keiner die Änderung des anderen mit einer alten Kopie.
    private func save() {
        guard !readOnly else { notice = Self.readOnlyText; return }
        let saved = locked { writeMerged() }
        guard isShared else { return }
        // nach dem Entsperren: das andere Programm liest sofort (bzw. Mountpoint repariert, wenn wir schreibgeschützt wurden)
        if saved || (passive && readOnly) { IPC.post("library") }
    }

    /// unter der Sperre: neu lesen, zusammenführen, schreiben
    private func writeMerged() -> Bool {
        let disk: Library
        switch readDisk() {
        case .ok(let lib): disk = lib
        case .missing:
            // erster Start oder gelöscht: zuletzt bekannter Stand (Workspaces schreibt ohnehin nur Mountpoint, merged)
            disk = loaded
        case .unreadable(let error) where passive:
            Log.write("library.json unreadable, protected volume change not saved and taken back: \(error)")
            // die abgelehnte Änderung zurücknehmen: das Fenster zeigt nur, was gespeichert ist
            library.guarded = loaded.guarded
            library.guardOwn = loaded.guardOwn
            readOnly = true
            notice = Self.readOnlyText
            return false
        case .unreadable(let error):
            // Mountpoint hat die vollständige Liste im Speicher: kaputte Datei beiseitelegen und sie neu schreiben
            guard let backup = setAside(error) else { notice = Self.cannotSetAside; return false }
            notice = loc("Your workspace list could not be read and was set aside as “\(backup)” (in ~/Library/Application Support/Mountpoint). Mountpoint saved the list it had open.")
            disk = loaded
        }
        let new = merged(onto: disk)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(new).write(to: file, options: .atomic)
            loaded = new
            knowsList = true
            if new != library { library = new; notifyGuard(); syncSidebar() }
            return true
        } catch {
            Log.write("saving library.json failed: \(error)")
            notice = loc("Your changes could not be saved. Check the free space on your Mac.") + "\n" + loc("Details: \(error.localizedDescription)")
            return false
        }
    }
}
