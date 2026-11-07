import AppKit
import Combine
import SwiftUI

/// Einstellungen in einem eigenen Fenster (macOS HIG „Settings“): Werkzeugleiste mit Reitern, die immer zeigt, welcher
/// Reiter aktiv ist; Fenstertitel = Reiter; Minimieren/Zoomen ausgegraut; zuletzt benutzter Reiter beim Öffnen; ⌘,.
/// 16:9 auf Wunsch des Nutzers (statt Höhe je Reiter) – längere Reiter scrollen. Das Panel bleibt offen (hold).
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
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if !isOpen { isOpen = true; hold(true) }
    }

    func close() { window?.performClose(nil) }

    private func build() {
        let tabs = SettingsTabs(tabStyle: .toolbar)
        for pane in Pane.allCases {
            let host = NSHostingController(rootView: SettingsPane(pane: pane))
            host.sizingOptions = []
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = min(UserDefaults.standard.integer(forKey: "settingsPane"), Pane.allCases.count - 1)
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]   // ohne miniaturizable/resizable: Minimieren und Zoomen sind ausgegraut
        w.toolbar?.allowsUserCustomization = false
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrame(NSRect(origin: .zero, size: Self.size), display: false)
        w.center()
        window = w
        self.tabs = tabs
        // Sprachwechsel ohne Neustart: Reiter und Fenstertitel mitziehen
        language = Store.shared.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let tabs = self.tabs else { return }
                for (item, pane) in zip(tabs.tabViewItems, Pane.allCases) {
                    item.label = pane.title
                    item.viewController?.title = pane.title
                }
                self.window?.title = Pane(rawValue: tabs.selectedTabViewItemIndex)?.title ?? ""
            }
        }
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
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: "settingsPane")
        if let w = view.window, w.frame.size != SettingsWindow.size {
            w.setFrame(NSRect(origin: w.frame.origin, size: SettingsWindow.size), display: true)
        }
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
    enum Support { case main, selfTest, problem }

    var body: some View {
        let t = Theme(dark: store.dark)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content(t) }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
        }
        .background(t.background)
        .environment(\.colorScheme, store.dark ? .dark : .light)
        .environment(\.locale, store.locale)
        .alert(loc("Mounted as network drive"), isPresented: $networkInfo) {
            Button("OK") {}
        } message: {
            Text("The Finder will warn that deleted items “will be deleted immediately” – that is right: Mountpoint volumes have no Trash. Applies the next time a workspace is mounted.")
        }
    }

    private func hint(_ text: LocalizedStringKey, _ t: Theme) -> some View {
        Text(text).font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
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
            SwitchRow(title: "Light/Dark", on: store.dark, theme: t) { store.dark.toggle() }
            row(Text("Language"), t) {
                Dropdown(title: Text(verbatim: languages.first { $0.code == store.language }?.name ?? "English"), theme: t) {
                    ForEach(languages, id: \.code) { l in
                        Button(l.name) { store.setLanguage(l.code) }.disabled(l.code == store.language)
                    }
                }
            }
            SwitchRow(title: "Show in the Finder sidebar", on: store.sidebar, theme: t) { store.sidebar.toggle() }
            hint("Mounted workspaces appear under “Locations”, like your other drives, and disappear again when they are ejected.", t)

        case .mediaComposer:
            SwitchRow(title: "Mount as network drive", on: store.network, theme: t) {
                store.network.toggle()
                if store.network { networkInfo = true }
            }
            hint("For collaboration with Avid Media Composer Enterprise: it then creates a “<computer name>.1” folder instead of “1”. Turn off “filter network drives” in Media Composer’s Media Creation settings. Applies the next time a workspace is mounted.", t)
            SwitchRow(title: "Warn about a “1” folder on network drives", on: store.watchNetwork, theme: t) { store.watchNetwork.toggle() }
            hint("On every connected network drive with “Avid MediaFiles”: warns when a folder “1” appears in MXF – a sign that someone is working without the bin locking of Media Composer Enterprise.", t)
            SwitchRow(title: "Warn about MXF folders with more than 5000 files", on: store.watchSize, theme: t) { store.watchSize.toggle() }
            hint("Checks the folders in “Avid MediaFiles/MXF” on all connected drives, the system volume and your workspaces once a minute – Media Composer gets slow when one holds more than 5000 files.", t)

        case .protected:
            hint("Warns as soon as Media Composer creates “Avid MediaFiles” on one of these volumes, e.g. LucidLink. “Workstation folder”: only when your Media Composer creates its folder in MXF – “1” on local drives, “<computer name>.1” on network drives with Media Composer Enterprise – not when others write. The system volume always watches the workstation folder.", t)
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
                SelfTestView(theme: t, test: test) { support = .main; test.reset() }
            case .problem:
                ProblemView(theme: t) { support = .main }
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
            }

        case .about:
            AboutView(theme: t)
        }
    }
}
