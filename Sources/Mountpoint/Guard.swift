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
         numbered: @escaping @MainActor () -> [FolderWatch] = { Store.shared.folderWatches() }) {
        self.names = names
        self.numbered = numbered
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

    /// Beobachter an die Liste und die eingehängten Volumes anpassen.
    func refresh() {
        let names = Set(self.names())
        for (name, source) in watchers where !names.contains(name) || !isVolume(name) {
            source.cancel()
            watchers[name] = nil
        }
        for name in names where watchers[name] == nil && isVolume(name) {
            // O_EVTONLY: blockiert das Auswerfen nicht
            let fd = open(path(name), O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
            source.setEventHandler { [weak self] in self?.check(name) }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[name] = source
        }
        for name in active where !names.contains(name) && !name.hasPrefix("n:") { closeAlert(name) }
        refreshNumbered()
        checkAll()
    }

    // MARK: nummerierte Ordner in MXF

    private func numberedFolders(_ w: FolderWatch) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: w.mxf)) ?? []).filter(w.matches).sorted()
    }

    private func refreshNumbered() {
        let watch = numbered()
        let keys = Set(watch.map(\.key))
        for (key, source) in mxfWatchers where !keys.contains(key) {
            source.cancel()
            mxfWatchers[key] = nil
        }
        for key in active where key.hasPrefix("n:") && !keys.contains(String(key.dropFirst(2))) { closeAlert(key) }
        for w in watch {
            // Was beim Einschalten schon da ist, gilt als bekannt – gewarnt wird bei neuen Ordnern.
            if knownNumbered[w.key] == nil { knownNumbered[w.key] = numberedFolders(w) }
            if mxfWatchers[w.key] == nil {
                let fd = open(w.mxf, O_EVTONLY)   // fehlt MXF noch, versucht es das Sicherheitsnetz später erneut
                if fd >= 0 {
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
                    let key = w.key
                    source.setEventHandler { [weak self] in
                        guard let self, let w = self.numbered().first(where: { $0.key == key }) else { return }
                        self.checkNumbered(w)
                    }
                    source.setCancelHandler { close(fd) }
                    source.resume()
                    mxfWatchers[w.key] = source
                }
            }
            checkNumbered(w)
        }
    }

    private func checkNumbered(_ w: FolderWatch) {
        let key = "n:" + w.key
        let current = numberedFolders(w)
        // Gelöschte Ordner vergessen: wird „1“ gelöscht und neu angelegt, warnt Mountpoint wieder.
        let known = Set(knownNumbered[w.key] ?? []).intersection(current)
        if known.count != (knownNumbered[w.key] ?? []).count { knownNumbered[w.key] = known.sorted() }
        let new = current.filter { !known.contains($0) }
        guard !new.isEmpty else { return }
        if let until = snoozed[key] {
            if until > Date() { return }
            snoozed[key] = nil
        }
        guard !active.contains(key) else { return }
        active.insert(key)
        if let presentNumbered { presentNumbered(w, new) } else { showNumberedAlert(w, new) }
    }

    /// „OK“: diese Ordner sind bekannt, gewarnt wird erst bei weiteren
    func acknowledgeNumbered(_ w: FolderWatch, _ folders: [String]) {
        knownNumbered[w.key, default: []].append(contentsOf: folders)
        closeAlert("n:" + w.key)
    }

    func checkAll() {
        names().forEach(check)
    }

    private func check(_ name: String) {
        guard names().contains(name), isVolume(name) else { return }
        guard FileManager.default.fileExists(atPath: path(name) + "/Avid MediaFiles") else {
            acknowledged.remove(name)
            return
        }
        if let until = snoozed[name] {
            if until > Date() { return }
            snoozed[name] = nil
        }
        guard !acknowledged.contains(name), !active.contains(name) else { return }
        active.insert(name)
        if let present { present(name) } else { showAlert(name) }
    }

    private func path(_ name: String) -> String { guardRoot(name) }

    /// Nur echte eingehängte Volumes, kein leerer Ordner in /Volumes. Das Systemvolume ist immer da.
    private func isVolume(_ name: String) -> Bool {
        if name == systemGuard { return true }
        var s = statfs()
        guard statfs(path(name), &s) == 0 else { return false }
        let on = withUnsafeBytes(of: s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return on == path(name)
    }

    // MARK: Alarmfenster

    private func showAlert(_ name: String) {
        let view = GuardAlert(title: String(localized: "Avid is writing to “\(guardName(name))”"),
            message: String(localized: "An “Avid MediaFiles” folder was created on this volume. Check your import or render target."),
            dark: Store.shared.dark,
            showInFinder: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.selectFile(self.path(name) + "/Avid MediaFiles", inFileViewerRootedAtPath: "")
            },
            snooze: { [weak self] choice in
                self?.snoozed[name] = snoozeEnd(choice)
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
            title = String(localized: "Avid is writing to “\(w.name)”: \(list)")
            message = String(localized: "Your Media Composer created its folder in “Avid MediaFiles/MXF” on this volume. Check your import or render target.")
        case .network:
            title = String(localized: "Folder “1” on “\(w.name)”")
            message = String(localized: "A folder “1” appeared in “Avid MediaFiles/MXF” on this network drive. A system writes to it as if it were a local drive – probably someone is working without bin locking. Find out who and check their Media Composer settings.")
        }
        let view = GuardAlert(title: title, message: message,
            dark: Store.shared.dark,
            showInFinder: {
                guard let first = folders.first else { return }
                NSWorkspace.shared.selectFile(w.mxf + "/" + first, inFileViewerRootedAtPath: "")
            },
            snooze: { [weak self] choice in
                self?.snoozed[key] = snoozeEnd(choice)
                self?.closeAlert(key)
            },
            dismiss: { [weak self] in self?.acknowledgeNumbered(w, folders) })
        presentPanel(view, key: key)
    }

    private func presentPanel(_ view: GuardAlert, key: String) {
        let panel = AlertPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = NSHostingController(rootView: view)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // über allem, auch über Media Composer im Vollbild
        panel.level = .statusBar
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

    private func label(_ s: Snooze) -> String {
        switch s {
        case .minutes(let m) where m < 60: return String(localized: "\(m) minutes")
        case .minutes(let m): return m == 60 ? String(localized: "1 hour") : String(localized: "\(m / 60) hours")
        case .restOfDay: return String(localized: "Rest of the day")
        }
    }
}
