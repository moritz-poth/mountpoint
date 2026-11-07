import AppKit
import SwiftUI

/// Ein MXF-Ordner, in dem neue Ordner eines Musters warnen.
struct FolderWatch {
    enum Kind { case own, network }
    /// merkt bekannte Ordner und Pausen
    let key: String
    let name: String
    let mxf: String
    let kind: Kind
    let matches: (String) -> Bool

    init(key: String, name: String, mxf: String, kind: Kind, matches: @escaping (String) -> Bool) {
        self.key = key
        self.name = name
        self.mxf = mxf
        self.kind = kind
        self.matches = matches
    }
}

/// Ordner, in dessen „Avid MediaFiles/MXF“ die Unterordner gezählt werden (Volume, Systemplatte, Workspace-Quelle).
struct SizeRoot: Hashable {
    let name: String
    let root: String
}

/// Anzahl der Einträge eines Ordners. Wo das Dateisystem es kann (APFS, HFS) mit einem Aufruf (ATTR_DIR_ENTRYCOUNT),
/// sonst (SMB, macFUSE) durch Zählen der Namen – ohne die Dateien selbst anzufassen.
func entryCount(_ path: String, quick: Bool = true) -> Int? {
    if quick {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.dirattr = attrgroup_t(ATTR_DIR_ENTRYCOUNT)
        var buf = [UInt8](repeating: 0, count: 64)
        if getattrlist(path, &list, &buf, buf.count, 0) == 0 {
            let n = buf.withUnsafeBytes { p -> Int? in
                let returned = p.load(fromByteOffset: 4, as: attribute_set_t.self)
                guard returned.dirattr & attrgroup_t(ATTR_DIR_ENTRYCOUNT) != 0 else { return nil }
                return Int(p.load(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: UInt32.self))
            }
            if let n { return n }
        }
    }
    guard let dir = opendir(path) else { return nil }
    defer { closedir(dir) }
    var n = 0
    while let e = readdir(dir) {
        let dot = withUnsafeBytes(of: e.pointee.d_name) { $0[0] == 0x2E && ($0[1] == 0 || ($0[1] == 0x2E && $0[2] == 0)) }
        if !dot { n += 1 }
    }
    return n
}

/// Zuletzt gezählte Ordner (Änderungszeit → Anzahl). Nur in der Warteschlange der Größenprüfung benutzt – darum unchecked.
private final class SizeCache: @unchecked Sendable {
    var entries: [String: (changed: timespec, counted: Date, count: Int)] = [:]
}

/// Warnt, sobald auf einem geschützten Volume „Avid MediaFiles“ entsteht.
/// Kein Scannen: macOS meldet Änderungen in der obersten Ebene (kqueue, 0 % CPU im Ruhezustand);
/// dazu einmal pro Minute ein einzelner Dateizugriff als Sicherheitsnetz.
@MainActor
final class VolumeGuard {
    static let shared = VolumeGuard()

    private let names: @MainActor () -> [String]
    /// MXF-Ordner, in denen neue nummerierte bzw. eigene Ordner warnen
    private let numbered: @MainActor () -> [FolderWatch]
    /// Anzeige des Alarms (Tests ersetzen sie)
    var present: ((String) -> Void)?
    var presentNumbered: ((FolderWatch, [String]) -> Void)?
    /// hält das Panel offen, solange ein Alarm offen ist – sonst schließt ein Klick auf den Alarm das Panel
    var hold: ((Bool) -> Void)?

    private var mxfWatchers: [String: DispatchSourceFileSystemObject] = [:]
    /// bereits bekannte bzw. bestätigte Ordner je Beobachtung (Warnung nur bei neuen)
    private var knownNumbered: [String: [String]] = (UserDefaults.standard.dictionary(forKey: "numberedKnown") as? [String: [String]]) ?? [:] {
        didSet { UserDefaults.standard.set(knownNumbered, forKey: "numberedKnown") }
    }

    init(names: @escaping @MainActor () -> [String] = { Store.shared.library.guarded.filter { !Store.shared.library.watchesOwn($0) } },
         numbered: @escaping @MainActor () -> [FolderWatch] = { Store.shared.folderWatches() },
         sizeRoots: @escaping @MainActor () -> [SizeRoot] = { Store.shared.sizeRoots() }) {
        self.names = names
        self.numbered = numbered
        self.sizeRoots = sizeRoots
    }

    // MARK: Größe der MXF-Ordner

    private let sizeRoots: @MainActor () -> [SizeRoot]
    /// Anzeige des Alarms „zu viele Dateien“ (Tests ersetzen sie): Volume, Ordnerpfad, Anzahl
    var presentSize: ((String, String, Int) -> Void)?
    /// mehr Dateien als das in einem MXF-Unterordner: Warnung
    var sizeLimit = 5000
    // eigene Warteschlange: ein hängendes Laufwerk hält weder die App noch die anderen Wächter auf
    private let sizeIO = DispatchQueue(label: "Mountpoint.size")
    private let sizeCache = SizeCache()
    private var sizing = false
    /// keine Größenprüfung unterwegs (für Tests)
    var sizeIdle: Bool { !sizing }
    /// mit „OK“ bestätigt: erst wieder, wenn der Ordner unter die Grenze fällt und erneut darüber steigt
    private var bigKnown: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "bigKnown") ?? []) {
        didSet { UserDefaults.standard.set(bigKnown.sorted(), forKey: "bigKnown") }
    }

    /// Zählt die Dateien in jedem Unterordner von „Avid MediaFiles/MXF“ – neu gezählt wird nur ein Ordner,
    /// dessen Änderungsdatum sich geändert hat; sonst kostet die Prüfung nur ein stat pro Ordner.
    func checkSizes() {
        let roots = sizeRoots()
        guard !roots.isEmpty else {
            for key in active where key.hasPrefix("s:") { closeAlert(key) }   // ausgeschaltet
            return
        }
        guard !sizing else { return }
        sizing = true
        let cache = sizeCache
        sizeIO.async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            var found: [(String, String, Int)] = []
            for r in roots {
                let mxf = r.root + "/Avid MediaFiles/MXF"
                for name in (try? FileManager.default.contentsOfDirectory(atPath: mxf)) ?? [] {
                    let folder = mxf + "/" + name
                    var st = stat()
                    guard stat(folder, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
                    let changed = st.st_mtimespec
                    // unverändert und vor weniger als 10 min gezählt: alte Zahl (manche Server melden Änderungen am Ordner nicht zuverlässig)
                    if let e = cache.entries[folder], e.changed.tv_sec == changed.tv_sec, e.changed.tv_nsec == changed.tv_nsec,
                       Date().timeIntervalSince(e.counted) < 600 {
                        found.append((r.name, folder, e.count))
                    } else if let n = entryCount(folder) {
                        cache.entries[folder] = (changed, Date(), n)
                        found.append((r.name, folder, n))
                    }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.applySizes(found) } }
        }
    }

    private func applySizes(_ found: [(String, String, Int)]) {
        sizing = false
        let over = found.filter { $0.2 > sizeLimit }
        let overPaths = Set(over.map(\.1))
        // wieder unter der Grenze (oder Laufwerk weg): vergessen, damit ein neues Überschreiten wieder warnt
        if !bigKnown.isSubset(of: overPaths) { bigKnown = bigKnown.intersection(overPaths) }
        for key in active where key.hasPrefix("s:") && !overPaths.contains(String(key.dropFirst(2))) { closeAlert(key) }
        for (volume, folder, n) in over where !bigKnown.contains(folder) {
            let key = "s:" + folder
            if let until = snoozed[key] {
                if until > Date() { continue }
                snoozed[key] = nil
            }
            guard !active.contains(key) else { continue }
            active.insert(key)
            Log.write("alert: \(n) files in \(folder)")
            if let presentSize { presentSize(volume, folder, n) } else { showSizeAlert(volume, folder, n) }
        }
    }

    /// „OK“: dieser Ordner ist bekannt, gewarnt wird erst wieder, wenn er unter die Grenze fällt und erneut darüber steigt
    func acknowledgeSize(_ folder: String) {
        bigKnown.insert(folder)
        closeAlert("s:" + folder)
    }

    private func showSizeAlert(_ volume: String, _ folder: String, _ count: Int) {
        let key = "s:" + folder
        let name = (folder as NSString).lastPathComponent
        let view = GuardAlert(title: loc("“\(name)” on “\(volume)” holds \(count) files"),
            message: loc("Folders in “Avid MediaFiles/MXF” should hold no more than 5000 files – Media Composer gets slow with bigger ones. Quit Media Composer and rename the folder, e.g. “1” to “1a”: the media stays online and Media Composer starts a new folder."),
            note: loc("We recommend rebalancing the folder with MediaFiles Check. You can find its GitHub repository at the following URL: [https://github.com/moritz-poth/mediafiles-check](https://github.com/moritz-poth/mediafiles-check)"),
            dark: Store.shared.dark,
            showInFinder: { NSWorkspace.shared.selectFile(folder, inFileViewerRootedAtPath: "") },
            snooze: { [weak self] choice in
                self?.snoozed[key] = snoozeEnd(choice)
                Log.write("alert snoozed until \(snoozeEnd(choice)): \(key)")
                self?.closeAlert(key)
            },
            dismiss: { [weak self] in self?.acknowledgeSize(folder) })
        presentPanel(view, key: key)
    }

    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    /// gespeichert, damit eine Pause („Rest des Tages“) einen Neustart übersteht
    private var snoozed: [String: Date] = (UserDefaults.standard.dictionary(forKey: "snoozed") as? [String: Date]) ?? [:] {
        didSet { UserDefaults.standard.set(snoozed, forKey: "snoozed") }
    }
    /// mit „OK“ bestätigt: erst wieder Alarm, wenn der Ordner neu angelegt wird
    private var acknowledged: Set<String> = []
    private var alerts: [String: NSPanel] = [:]
    /// Volumes mit offenem Alarm (auch ohne Fenster, z. B. in Tests)
    private var active: Set<String> = []
    private var timer: Timer?

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Dateizugriffe laufen nur hier, nie im Hauptthread: ein hängendes Laufwerk hält höchstens den Wächter auf, nie die App.
    // shortcut: ein hängendes Laufwerk hält auch die Prüfung der anderen auf, bis es antwortet; erst trennen, wenn das stört.
    private let io = DispatchQueue(label: "Mountpoint.guard")
    private var scanning = false
    private var rescan = false
    /// keine Prüfung unterwegs (für Tests)
    var idle: Bool { !scanning }

    /// Beobachter an die Liste und die eingehängten Volumes anpassen.
    func refresh() {
        let names = Set(self.names().filter(isVolume))
        let keys = Set(numbered().map(\.key))
        for (name, source) in watchers where !names.contains(name) {
            source.cancel()
            watchers[name] = nil
        }
        for (key, source) in mxfWatchers where !keys.contains(key) {
            source.cancel()
            mxfWatchers[key] = nil
        }
        for key in active where !key.hasPrefix("s:") && (key.hasPrefix("n:") ? !keys.contains(String(key.dropFirst(2))) : !names.contains(key)) { closeAlert(key) }
        scan()
        checkSizes()
    }

    /// Ordner im Hintergrund lesen, im Hauptthread auswerten. Ereignisse während eines Durchlaufs ergeben genau einen weiteren.
    private func scan() {
        guard !scanning else { rescan = true; return }
        scanning = true
        let names = self.names().filter(isVolume)
        let watches = numbered()
        let needRoot = Set(names.filter { watchers[$0] == nil })
        let needMXF = Set(watches.filter { mxfWatchers[$0.key] == nil }.map(\.key))
        io.async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            // O_EVTONLY: blockiert das Auswerfen nicht
            let roots = names.map { name in
                (name, FileManager.default.fileExists(atPath: guardRoot(name) + "/Avid MediaFiles"),
                 needRoot.contains(name) ? open(guardRoot(name), O_EVTONLY) : -1)
            }
            // fehlt MXF noch, versucht es das Sicherheitsnetz (60 s) später erneut
            let mxf = watches.map { w in (w, Self.folders(w), needMXF.contains(w.key) ? open(w.mxf, O_EVTONLY) : -1) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(roots, mxf) } }
        }
    }

    private func apply(_ roots: [(String, Bool, Int32)], _ mxf: [(FolderWatch, [String]?, Int32)]) {
        let names = Set(self.names())
        let keys = Set(numbered().map(\.key))
        for (name, exists, fd) in roots {
            if fd >= 0 {
                if watchers[name] == nil && names.contains(name) { watchers[name] = source(fd) } else { close(fd) }
            }
            if names.contains(name) { check(name, exists: exists) }
        }
        for (w, folders, fd) in mxf {
            if fd >= 0 {
                if mxfWatchers[w.key] == nil && keys.contains(w.key) { mxfWatchers[w.key] = source(fd) } else { close(fd) }
            }
            if keys.contains(w.key), let folders { checkNumbered(w, folders) }
        }
        scanning = false
        if rescan {
            rescan = false
            scan()
        }
    }

    private func source(_ fd: Int32) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        source.setEventHandler { [weak self, unowned source] in
            MainActor.assumeIsolated {
                // Das Volume wird ausgeworfen: nichts mehr darauf öffnen. Ein Zugriff mitten im Auswerfen blockierte
                // macFUSE-Volumes im Kernel samt umount (gefunden im Test 2026-11-06); refresh räumt den Beobachter weg.
                if source.data.contains(.revoke) {
                    source.cancel()
                    return
                }
                self?.scan()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    // MARK: nummerierte Ordner in MXF

    /// Passende Ordner in MXF; leer, wenn MXF (noch) fehlt; nil, wenn sich der Ordner nicht lesen lässt.
    nonisolated private static func folders(_ w: FolderWatch) -> [String]? {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: w.mxf).filter(w.matches).sorted()
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {
            return []
        } catch {
            return nil
        }
    }

    private func checkNumbered(_ w: FolderWatch, _ current: [String]) {
        // Was beim Einschalten schon da ist, gilt als bekannt – gewarnt wird bei neuen Ordnern.
        guard let before = knownNumbered[w.key] else {
            knownNumbered[w.key] = current
            return
        }
        let key = "n:" + w.key
        // Gelöschte Ordner vergessen: wird „1“ gelöscht und neu angelegt, warnt Mountpoint wieder.
        let known = Set(before).intersection(current)
        if known.count != before.count { knownNumbered[w.key] = known.sorted() }
        let new = current.filter { !known.contains($0) }
        guard !new.isEmpty else { return }
        if let until = snoozed[key] {
            if until > Date() { return }
            snoozed[key] = nil
        }
        guard !active.contains(key) else { return }
        active.insert(key)
        Log.write("alert: \(new.joined(separator: ", ")) in \(w.mxf)")
        if let presentNumbered { presentNumbered(w, new) } else { showNumberedAlert(w, new) }
    }

    /// „OK“: diese Ordner sind bekannt, gewarnt wird erst bei weiteren
    func acknowledgeNumbered(_ w: FolderWatch, _ folders: [String]) {
        knownNumbered[w.key, default: []].append(contentsOf: folders)
        closeAlert("n:" + w.key)
    }

    private func check(_ name: String, exists: Bool) {
        guard exists else {
            acknowledged.remove(name)
            return
        }
        if let until = snoozed[name] {
            if until > Date() { return }
            snoozed[name] = nil
        }
        guard !acknowledged.contains(name), !active.contains(name) else { return }
        active.insert(name)
        Log.write("alert: “Avid MediaFiles” on \(guardRoot(name))")
        if let present { present(name) } else { showAlert(name) }
    }

    private func path(_ name: String) -> String { guardRoot(name) }

    /// Nur echte eingehängte Volumes, kein leerer Ordner in /Volumes. Das Systemvolume ist immer da.
    private func isVolume(_ name: String) -> Bool {
        name == systemGuard || Mounter.isMountPoint(path(name))
    }

    // MARK: Alarmfenster

    private func showAlert(_ name: String) {
        let view = GuardAlert(title: loc("Media Composer is writing to “\(guardName(name))”"),
            message: loc("An “Avid MediaFiles” folder was created on this volume. Check your import or render target."),
            dark: Store.shared.dark,
            showInFinder: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.selectFile(self.path(name) + "/Avid MediaFiles", inFileViewerRootedAtPath: "")
            },
            snooze: { [weak self] choice in
                self?.snoozed[name] = snoozeEnd(choice)
                Log.write("alert snoozed until \(snoozeEnd(choice)): \(name)")
                self?.closeAlert(name)
            },
            dismiss: { [weak self] in
                self?.acknowledged.insert(name)
                self?.closeAlert(name)
            })
        presentPanel(view, key: name)
    }

    private func showNumberedAlert(_ w: FolderWatch, _ folders: [String]) {
        let key = "n:" + w.key
        let list = folders.map { "„\($0)“" }.joined(separator: ", ")
        let title, message: String
        switch w.kind {
        case .own:
            title = loc("Media Composer is writing to “\(w.name)”: \(list)")
            message = loc("Your Media Composer created its folder in “Avid MediaFiles/MXF” on this volume. Check your import or render target.")
        case .network:
            title = loc("Folder “1” on “\(w.name)”")
            message = loc("A folder “1” appeared in “Avid MediaFiles/MXF” on this network drive. A system writes to it as if it were a local drive – probably someone is working without the bin locking of Media Composer Enterprise. Find out who and check their Media Composer settings.")
        }
        let view = GuardAlert(title: title, message: message,
            dark: Store.shared.dark,
            showInFinder: {
                guard let first = folders.first else { return }
                NSWorkspace.shared.selectFile(w.mxf + "/" + first, inFileViewerRootedAtPath: "")
            },
            snooze: { [weak self] choice in
                self?.snoozed[key] = snoozeEnd(choice)
                Log.write("alert snoozed until \(snoozeEnd(choice)): \(key)")
                self?.closeAlert(key)
            },
            dismiss: { [weak self] in self?.acknowledgeNumbered(w, folders) })
        presentPanel(view, key: key)
    }

    private func presentPanel(_ view: GuardAlert, key: String) {
        let panel = AlertPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = NSHostingController(rootView: view.environment(\.locale, Store.shared.locale))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // über allem, auch über Media Composer im Vollbild
        panel.level = .statusBar
        panel.hidesOnDeactivate = false   // NSPanel verschwindet sonst, sobald eine andere App aktiv ist (Start nach Update, Systemabfrage)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.setContentSize(panel.contentViewController!.view.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            // Bildschirmmitte; weitere Alarme leicht versetzt darunter
            let offset = CGFloat(alerts.count) * 24
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2 + offset,
                                         y: screen.midY - panel.frame.height / 2 - offset))
        }
        panel.orderFrontRegardless()
        hold?(true)
        NSSound.beep()
        alerts[key] = panel
    }

    private func closeAlert(_ name: String) {
        if let panel = alerts[name] { panel.close(); hold?(false) }
        alerts[name] = nil
        active.remove(name)
    }
}

/// Rahmenloses Fenster, das trotzdem Klicks und Tastatur annimmt.
final class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct GuardAlert: View {
    let title: String
    let message: String
    /// zweiter Absatz, Markdown (Links sind klickbar)
    var note: String? = nil
    let dark: Bool
    let showInFinder: () -> Void
    let snooze: (Snooze) -> Void
    let dismiss: () -> Void

    var body: some View {
        let t = Theme(dark: dark)
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                // Dreieck mittig zur Überschrift
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(t.partial)
                        .frame(width: 24)
                    Text(title)
                        .font(.mono(14, semibold: true))
                        .foregroundColor(t.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(message)
                    .font(.mono(12))
                    .foregroundColor(t.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36)
                if let note {
                    Text(linked(note))
                        .font(.mono(12))
                        .foregroundColor(t.muted)
                        .tint(t.text)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 36)
                }
            }
            HStack(spacing: 12) {
                Button("Show in Finder", action: showInFinder)
                    .buttonStyle(FerryButtonStyle(theme: t, height: 32))
                Dropdown(title: Text("Snooze alert…"), theme: t, height: 32) {
                    ForEach(Snooze.all, id: \.self) { choice in
                        Button(label(choice)) { snooze(choice) }
                    }
                }
                Spacer()
                Button("OK", action: dismiss)
                    .buttonStyle(FerryButtonStyle(theme: t, primary: true, height: 32))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 10).fill(t.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.line, lineWidth: 1))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// Markdown-Links unterstrichen, damit man sieht, dass sie klickbar sind
    private func linked(_ md: String) -> AttributedString {
        var a = (try? AttributedString(markdown: md)) ?? AttributedString(md)
        for run in a.runs where run.link != nil { a[run.range].underlineStyle = .single }
        return a
    }

    private func label(_ s: Snooze) -> String {
        switch s {
        case .minutes(let m) where m < 60: return loc("\(m) minutes")
        case .minutes(let m): return m == 60 ? loc("1 hour") : loc("\(m / 60) hours")
        case .restOfDay: return loc("Rest of the day")
        }
    }
}
