import AppKit
import Combine
import SwiftUI

/// Einstellungen in einem eigenen Fenster (macOS HIG „Settings“): Werkzeugleiste mit Reitern, die immer zeigt, welcher
/// Reiter aktiv ist; Fenstertitel immer „Mountpoint“; Minimieren/Zoomen ausgegraut; zuletzt benutzter Reiter beim Öffnen; ⌘,.
/// 16:9 auf Wunsch des Nutzers (statt Höhe je Reiter); kein Reiter scrollt, nur die Liste der geschützten Volumes.
/// Seit 1.2 läuft das Fenster in der Einstellungs-App (SettingsApp.swift); im Mountpoint-Prozess nur bei Entwicklungs-Builds.
@MainActor
final class SettingsWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    enum Pane: Int, CaseIterable {
        case general, mediaComposer, protected, updates, support, about
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .mediaComposer: return "film"
            case .protected: return "lock.shield"
            case .updates: return "arrow.triangle.2.circlepath"
            case .support: return "lifepreserver"
            case .about: return "info.circle"
            }
        }
        /// gleicht die erste Zeile an die Zeilen mit Button (Updates, Support) an: in jedem Reiter dieselbe Höhe
        var firstLine: CGFloat {
            switch self {
            case .general, .mediaComposer: return 3   // Schalter 20 statt Button 26 hoch
            case .protected: return 4.5               // beginnt mit einem Hinweis in 11 pt
            case .about: return 1.5                   // Titel 15 pt neben dem Symbol
            case .updates, .support: return 0
            }
        }
        var title: String {
            switch self {
            case .general: return loc("General")
            case .mediaComposer: return loc("Avid Media Composer")
            case .protected: return loc("Protected volumes")
            case .updates: return loc("Updates")
            case .support: return loc("Support")
            case .about: return loc("About")
            }
        }
    }

    @Published private(set) var isOpen = false
    /// hält das Panel offen, solange das Fenster offen ist (AppDelegate.hold)
    var hold: (Bool) -> Void = { _ in }
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private var language: AnyCancellable?
    static let size = NSSize(width: 800, height: 450)   // 16:9, ganzes Fenster

    func show(_ pane: Pane? = nil) {
        if window == nil { build() }
        if let pane { tabs?.selectedTabViewItemIndex = pane.rawValue }
        // bleibt reine Menüleisten-App (kein Dock-Symbol/⌘-Tab: das Umschalten war unzuverlässig, siehe CLAUDE.md);
        // das Fenster liegt über allem und verschwindet mit Mountpoint beim Wechsel in eine andere App
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if !isOpen { isOpen = true; hold(true) }
    }

    /// nach dem Zurückwechseln zu Mountpoint: Fenster wieder nach vorn
    func front() { window?.orderFrontRegardless() }

    func close() { window?.performClose(nil) }

    private func build() {
        let tabs = SettingsTabs(tabStyle: .toolbar)
        tabs.canPropagateSelectedChildViewControllerTitle = false   // Fenstertitel bleibt „Mountpoint“ (Nutzerwunsch), nicht der Reiter
        for pane in Pane.allCases {
            let host = NSHostingController(rootView: SettingsPane(pane: pane))
            host.sizingOptions = []
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = min(defaults.integer(forKey: "settingsPane"), Pane.allCases.count - 1)
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]   // ohne miniaturizable/resizable: Minimieren und Zoomen sind ausgegraut
        w.toolbar?.allowsUserCustomization = false
        w.toolbarStyle = .preference
        w.title = "Mountpoint"
        w.isReleasedWhenClosed = false
        if !settingsMode {
            // im Mountpoint-Prozess (Entwicklungs-Build ohne Einstellungs-App): über dem Panel, verschwindet mit der App
            w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            w.hidesOnDeactivate = true
        }
        w.delegate = self
        w.setFrame(NSRect(origin: .zero, size: Self.size), display: false)
        w.center()
        window = w
        self.tabs = tabs
        // Sprachwechsel ohne Neustart: Reiter mitziehen
        language = Store.shared.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let tabs = self.tabs else { return }
                for (item, pane) in zip(tabs.tabViewItems, Pane.allCases) {
                    item.label = pane.title
                    item.viewController?.title = pane.title
                }
            }
        }
    }

    static var closesAfterTest: String { loc("The self-test is still running. The settings close by themselves when it is done.") }
    private var closeAfterTest: AnyCancellable?

    /// Einstellungs-App: während des Selbsttests offen bleiben (sie beendet sich mit dem Fenster) und danach selbst schließen
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard settingsMode, SelfTest.shared.phase == .running else { return true }
        Store.shared.notice = Self.closesAfterTest
        closeAfterTest = SelfTest.shared.$phase.filter { $0 != .running }.first().sink { [weak self] _ in
            DispatchQueue.main.async { self?.window?.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        hold(false)
    }
}

/// Merkt sich den Reiter und hält die Fenstergröße fest (16:9), auch wenn ein Reiter mehr Inhalt hat.
final class SettingsTabs: NSTabViewController {
    convenience init(tabStyle: NSTabViewController.TabStyle) {
        self.init()
        self.tabStyle = tabStyle
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        defaults.set(selectedTabViewItemIndex, forKey: "settingsPane")
        if let w = view.window, w.frame.size != SettingsWindow.size {
            w.setFrame(NSRect(origin: w.frame.origin, size: SettingsWindow.size), display: true)
        }
    }
}

/// „Warnen bei MXF-Ordnern mit mehr als [5000] Dateien“ – Grenze wie in MediaFiles Check (100…50000), in der Schalterzeile,
/// damit der Reiter nicht wächst. Gilt erst nach Enter oder beim Verlassen des Felds (sonst würde „500“ unterwegs schon warnen);
/// ungültige Eingaben: roter Rahmen, danach zurück auf den alten Wert.
private struct SizeLimitRow: View {
    @ObservedObject var store: Store
    let theme: Theme
    @State private var text = ""
    @FocusState private var focused: Bool
    private var valid: Bool { Int(text).map(Store.limitRange.contains) ?? false }

    var body: some View {
        let t = theme
        HStack(spacing: 8) {
            Text("Warn about MXF folders with more than").font(.mono()).foregroundColor(t.text).fixedSize(horizontal: false, vertical: true)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.mono())
                .foregroundColor(t.text)
                .multilineTextAlignment(.center)
                .focused($focused)
                .onSubmit(commit)
                .frame(width: 58, height: 20)   // so hoch wie der Schalter: der Reiter ist in fr fast voll
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(valid ? t.line : t.error, lineWidth: 1))
                .accessibilityLabel(Text("Files per folder"))
            Text("files").font(.mono()).foregroundColor(t.text)
            Spacer(minLength: 8)
            Switch(on: store.watchSize, theme: t) { store.watchSize.toggle() }
                .accessibilityLabel(Text("Warn about MXF folders with more than"))
        }
        .onAppear { text = String(store.sizeLimit) }
        .onDisappear(perform: commit)
        .onChange(of: focused) { if !$0 { commit() } }
        .onChange(of: store.sizeLimit) { text = String($0) }
    }

    private func commit() {
        if valid, let n = Int(text), n != store.sizeLimit { store.sizeLimit = n } else { text = String(store.sizeLimit) }
    }
}

/// Inhalt eines Reiters: Ferry-Look (Theme, Mono-Schrift), Spalte mittig, scrollt bei Bedarf.
struct SettingsPane: View {
    let pane: SettingsWindow.Pane
    @ObservedObject private var store = Store.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var test = SelfTest.shared
    @State private var support = Support.main
    @State private var networkInfo = false
    @State private var toast: Toast?
    enum Support { case main, selfTest, problem }

    var body: some View {
        let t = Theme(dark: store.dark)
        // nie scrollen: jeder Reiter passt ins Fenster; nur die Volume-Liste scrollt in sich
        VStack(alignment: .leading, spacing: 14) {
            // Fehler der Einstellungs-App (Speichern, unlesbare Liste, Anmeldeobjekt) – sonst wären sie unsichtbar
            if let notice = store.notice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundColor(t.partial)
                    Text(notice).font(.mono(11)).foregroundColor(t.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { store.notice = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(t.muted)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Close"))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(t.partial.opacity(0.12)))
            }
            content(t).padding(.top, pane.firstLine)
        }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 16)   // Platz für die längeren Texte in de/fr/es, damit „Avid Media Composer“ nicht überläuft
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(t.background)
            .toast($toast, theme: Theme(dark: store.dark))
            .overlay { if networkInfo { networkCard(Theme(dark: store.dark)) } }
        .environment(\.colorScheme, store.dark ? .dark : .light)
        .environment(\.locale, store.locale)
    }

    /// Hinweis nach dem Einschalten von „Als Netzlaufwerk“ – als Karte im Mountpoint-Stil wie im Panel, kein Systemdialog
    private func networkCard(_ t: Theme) -> some View {
        ZStack {
            Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { networkInfo = false }
            VStack(alignment: .leading, spacing: 14) {
                Text("Mounted as network drive").font(.mono(13, semibold: true)).foregroundColor(t.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The Finder will warn that deleted items “will be deleted immediately” – that is right: Mountpoint volumes have no Trash. Applies the next time a workspace is mounted.")
                    .font(.mono(12)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("OK") { networkInfo = false }
                        .buttonStyle(FerryButtonStyle(theme: t, primary: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 420)
            .background(RoundedRectangle(cornerRadius: 10).fill(t.background))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }

    /// Senden fertig: Meldung zeigen, bei Erfolg zurück zur Support-Übersicht (wie nach „Zurück“)
    private func reported(_ outcome: Reporter.Outcome) {
        toast = Toast(outcome)
        guard case .sent = outcome else { return }
        if support == .selfTest { test.reset() }
        support = .main
    }

    /// Erklärung unter einer Zeile – bricht vor der Spalte mit Schaltern und Buttons um (Spalte 560, Text max. 390);
    /// `fullWidth`, wo daneben kein Schalter steht (Einleitung der geschützten Volumes)
    private func hint(_ text: LocalizedStringKey, _ t: Theme, fullWidth: Bool = false) -> some View {
        Text(text).font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: fullWidth ? .infinity : 390, alignment: .leading)
    }

    /// Zeile wie „Version … / Nach Updates suchen“: kurzer Text links, Bedienelement rechtsbündig
    private func row<C: View>(_ text: Text, _ t: Theme, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 10) {
            text.font(.mono()).foregroundColor(t.text)
            Spacer()
            control()
        }
    }

    @ViewBuilder private func content(_ t: Theme) -> some View {
        switch pane {
        case .general:
            SwitchRow(title: "Launch at login", on: store.launchAtLogin, theme: t) { store.setLaunchAtLogin(!store.launchAtLogin) }
            hint("Starts Mountpoint when you log in, so projects set to “Mount at app launch” are ready right away.", t)
            SwitchRow(title: "Light/Dark", on: store.dark, theme: t) { store.dark.toggle() }
            hint("Switches the panel, the settings and the alerts between a light and a dark look.", t)
            row(Text("Language"), t) {
                Dropdown(title: Text(verbatim: languages.first { $0.code == store.language }?.name ?? "English"), theme: t) {
                    ForEach(languages, id: \.code) { l in
                        Button(l.name) { store.setLanguage(l.code) }.disabled(l.code == store.language)
                    }
                }
            }
            SwitchRow(title: "Show in the Finder sidebar", on: store.sidebar, theme: t) { store.sidebar.toggle() }
            hint("Mounted workspaces appear under “Locations”, like your other drives, and disappear again when they are ejected.", t)
            // nur wenn Mountpoint beim Start keinen Zugriff auf die Liste hatte (Sidebar.accessKey); erklärt wird es beim
            // ersten Start (SidebarAccess) – hier nur die Zeile, die Seite scrollt nie
            if defaults.object(forKey: Sidebar.accessKey) as? Bool == false {
                row(Text("Remove old sidebar entries"), t) {
                    Button("Allow…") { NSWorkspace.shared.open(SidebarAccess.settingsURL) }.buttonStyle(FerryButtonStyle(theme: t))
                }
            }

        case .mediaComposer:
            SwitchRow(title: "Mount as network drive", on: store.network, theme: t) {
                store.network.toggle()
                if store.network { networkInfo = true }
            }
            hint("For collaboration with Avid Media Composer Enterprise: it then creates a “<computer name>.1” folder instead of “1”. Turn off “filter network drives” in Media Composer’s Media Creation settings. Applies the next time a workspace is mounted.", t)
            SwitchRow(title: "Warn about a “1” folder on network drives", on: store.watchNetwork, theme: t) { store.watchNetwork.toggle() }
            hint("On every connected network drive with “Avid MediaFiles”: warns when a folder “1” appears in MXF – a sign that someone is working without the bin locking of Media Composer Enterprise.", t)
            SizeLimitRow(store: store, theme: t)
            hint("Use the same limit as in MediaFiles Check. A first warning comes above 90 %.", t)

        case .protected:
            hint("Warns as soon as Media Composer creates “Avid MediaFiles” on one of these volumes, e.g. LucidLink. “Workstation folder”: only when your Media Composer creates its folder in MXF – “1” on local drives, “<computer name>.1” on network drives with Media Composer Enterprise – not when others write. The system volume always watches the workstation folder.", t, fullWidth: true)
            // nur die Liste scrollt (ab etwa 5 Volumes); „Volume hinzufügen“ bleibt darunter immer sichtbar
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.library.guarded, id: \.self) { name in
                        let own = store.library.watchesOwn(name)
                        HStack(spacing: 10) {
                            Image(systemName: "shield").font(.system(size: 11)).foregroundColor(t.muted).frame(width: 14)
                            Text(guardName(name)).font(.mono(12)).foregroundColor(t.text).lineLimit(1).truncationMode(.middle)
                                .help(guardRoot(name))
                                .frame(height: 26)
                            Spacer()
                            // Systemvolume ohne Auswahl: „Avid MediaFiles“ gibt es dort immer, es zählt der Workstation-Ordner
                            if name != systemGuard {
                                Dropdown(title: own ? Text("Workstation folder") : Text(verbatim: "Avid MediaFiles"), theme: t) {
                                    Button("Avid MediaFiles") { store.setGuardOwn(name, false) }.disabled(!own)
                                    Button("Workstation folder") { store.setGuardOwn(name, true) }.disabled(own)
                                }
                            }
                            Button { store.removeGuard(name) } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(t.muted)
                                    .frame(width: 18, height: 18).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(Text("Remove"))
                            .accessibilityLabel(Text("Remove \(name)"))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(CGFloat(store.library.guarded.count) * 36, 180))
            let candidates = store.guardCandidates()
            row(Text("Protect volume"), t) {
                Dropdown(title: Text("Add volume…"), theme: t) {
                    ForEach(candidates, id: \.self) { name in Button(guardName(name)) { store.addGuard(name) } }
                }
                .disabled(candidates.isEmpty)
            }

        case .updates:
            row(Text("Version \(Updater.current)"), t) {
                if updater.state == .checking { ProgressView().controlSize(.small) }
                Button("Check for updates") { updater.check(manual: true) }
                    .buttonStyle(FerryButtonStyle(theme: t))
                    .disabled(updater.state == .checking || updater.state == .installing)
            }
            if let release = updater.available, settingsMode {
                // installieren kann nur Mountpoint selbst – Panel mit dem Update-Hinweis öffnen
                row(Text("Mountpoint \(release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag) is available."), t) {
                    Button("Show in Mountpoint") { SettingsLauncher.showUpdateInMountpoint() }
                        .buttonStyle(FerryButtonStyle(theme: t, primary: true))
                }
            }
            switch updater.state {
            case .upToDate:
                Text("Mountpoint is up to date.").font(.mono(11)).foregroundColor(t.faint)
            case .failed(let message) where updater.available == nil:
                Text(message).font(.mono(11)).foregroundColor(t.partial).fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
            hint("Mountpoint checks GitHub for new versions on its own and shows a notice.", t)
            SwitchRow(title: "Get test versions", on: store.betas, theme: t) { store.betas.toggle(); updater.check(manual: false) }
            hint("Also offers versions that are still being tested. For testers only – they can contain errors.", t)

        case .support:
            switch support {
            case .selfTest:
                // Liste 190: mit Zusammenfassung und Buttons passt die Ergebnisseite sonst nicht ganz ins Fenster
                SelfTestView(theme: t, test: test, listHeight: 190, done: { support = .main; test.reset() }, sent: reported)
            case .problem:
                ProblemView(theme: t, editorHeight: 110, done: { support = .main }, sent: reported)
            case .main:
                row(test.phase == .running ? Text("Self-test running…") : Text("Test this Mac"), t) {
                    Button("Run self-test…") { support = .selfTest }.buttonStyle(FerryButtonStyle(theme: t))
                }
                hint("Tests mounting, files, warnings and updates on a test disk of its own and sends us an anonymous report.", t)
                row(Text("Problem or idea?"), t) {
                    Button("Report…") { support = .problem }.buttonStyle(FerryButtonStyle(theme: t))
                }
                hint("No GitHub account needed.", t)
                // für Fehlerberichte: Ereignisse, Fehler und Alarme stehen dort
                row(Text("Events and errors"), t) {
                    Button("Show log file") { Log.reveal() }.buttonStyle(FerryButtonStyle(theme: t))
                }
                row(Text("Like Mountpoint?"), t) {
                    Button("Buy me a coffee") { NSWorkspace.shared.open(AboutView.coffee) }.buttonStyle(FerryButtonStyle(theme: t))
                }
                hint("If you use Mountpoint and like it, I would be glad if you bought me a coffee.", t)
            }

        case .about:
            AboutView(theme: t)
        }
    }
}
