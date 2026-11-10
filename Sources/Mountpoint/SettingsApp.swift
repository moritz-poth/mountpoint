import AppKit
import Combine
import CoreText
import SwiftUI

/// Die Einstellungen als eigene kleine App (Mountpoint.app/Contents/Helpers/Mountpoint Settings.app, derselbe Code):
/// eine normale App steht beim Start von selbst vorn in ⌘-Tab und hat ihr Dock-Symbol – ohne die unzuverlässigen
/// Tricks mit der Aktivierungsart (1.1.1–1.1.3). Sie ist passiv (Store.passive): Einstellungen und library.json lesen
/// und schreiben, Mountpoint per IPC Bescheid geben; Startobjekt und Updates erledigt Mountpoint selbst.

/// Mountpoint-Seite: öffnet die Einstellungs-App und weiß, ob sie läuft (Zahnrad gefüllt, Panel halten).
@MainActor
final class SettingsLauncher: ObservableObject {
    static let shared = SettingsLauncher()
    nonisolated static let bundleID = mainBundleID + ".settings"
    static var appURL: URL { mainBundleURL.appendingPathComponent("Contents/Helpers/Mountpoint Settings.app") }

    @Published private(set) var isOpen = false

    /// Beim Beenden von Mountpoint: eine offene Einstellungs-App mit beenden (läuft dort ein Selbsttest, beendet sie sich
    /// danach). Vor einem Update (`wait`): bis 5 s warten, dann hart beenden – sonst liefe die alte Version aus dem
    /// Papierkorb weiter. Ein Update startet nie während eines Selbsttests (Updater.install), hart beendet wird also kein Test.
    nonisolated static func terminateRunning(wait: Bool = false) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        apps.forEach { $0.terminate() }
        guard wait else { return }
        let deadline = Date().addingTimeInterval(5)
        for app in apps {
            while kill(app.processIdentifier, 0) == 0 && Date() < deadline { usleep(100_000) }
            if kill(app.processIdentifier, 0) == 0 {
                Log.write("settings app did not quit, forcing it")
                app.forceTerminate()
            }
        }
    }

    /// Einstellungs-App, Reiter Updates: Panel mit dem Update-Hinweis zeigen – läuft Mountpoint nicht, starten
    static func showUpdateInMountpoint() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleID).isEmpty else { IPC.post("showUpdate"); return }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--show-update"]
        NSWorkspace.shared.openApplication(at: mainBundleURL, configuration: config) { _, error in
            guard let error else { return }
            Log.write("Mountpoint could not be opened: \(error.localizedDescription)")
            let text = error.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Store.shared.notice = loc("Mountpoint could not be opened. Open it from the Applications folder.") + "\n" + loc("Details: \(text)")
                }
            }
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var inProcess: AnyCancellable?

    private var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }
    /// Entwicklungs-Builds ohne Helfer-Bundle: Fenster im eigenen Prozess (wie 1.1.4)
    private var external: Bool { FileManager.default.fileExists(atPath: Self.appURL.path) }

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        let bundle = Self.bundle
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard bundle(n) == Self.bundleID else { return }
            MainActor.assumeIsolated { self?.set(true) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard bundle(n) == Self.bundleID else { return }
            MainActor.assumeIsolated { self?.set(false) }
        })
        inProcess = SettingsWindow.shared.$isOpen.dropFirst().sink { [weak self] open in self?.set(open) }
        isOpen = running
    }

    nonisolated private static func bundle(_ n: Notification) -> String? {
        (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    private func set(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
    }

    func open(_ pane: SettingsWindow.Pane? = nil) {
        guard external else { SettingsWindow.shared.show(pane); return }
        if let pane, running { IPC.post("pane", ["pane": String(pane.rawValue)]) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let pane { config.arguments = ["--pane", String(pane.rawValue)] }
        NSWorkspace.shared.openApplication(at: Self.appURL, configuration: config) { _, error in
            guard let error else { return }
            Log.write("settings app could not be opened: \(error.localizedDescription)")
            // z. B. Gatekeeper blockiert die eingebettete App: Einstellungen im eigenen Fenster statt gar nichts
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SettingsWindow.shared.show(pane)
                }
            }
        }
    }
}

/// Einstellungs-App: nur das Fenster; beendet sich, wenn es geschlossen wird.
@MainActor
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    private let actions = MenuActions()
    private var language: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts") ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        // erst zuhören, dann laden: ein Speichern von Mountpoint dazwischen geht sonst verloren
        IPC.listen { what, info in
            switch what {
            case "settings": Store.shared.reloadSettings()
            case "library": Store.shared.reloadLibrary()
            case "launchAtLoginResult": Store.shared.launchAtLoginResult(on: info["on"] == "1", error: info["error"] ?? "", request: info["id"] ?? "")
            case "pane": SettingsWindow.shared.show(Int(info["pane"] ?? "").flatMap(SettingsWindow.Pane.init(rawValue:)))
            default: break
            }
        }
        let store = Store.shared
        store.reloadLibrary()
        IPC.post("launchAtLoginQuery")   // aktuellen Zustand holen (auch nach Änderungen in den Systemeinstellungen)
        store.applyAppearance()
        buildMainMenu(actions)
        language = store.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { if let self { buildMainMenu(self.actions) } }
        }
        let args = CommandLine.arguments
        let pane = args.firstIndex(of: "--pane").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
        SettingsWindow.shared.show(pane.flatMap(SettingsWindow.Pane.init(rawValue:)))
    }

    /// Mitten im Selbsttest nicht beenden: Testvolumes, Disk-Image und ein angehaltener Helfer blieben sonst zurück.
    /// Das Fenster bleibt dann offen und sagt das (SettingsWindow.windowShouldClose); zu geht es erst danach.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SelfTest.shared.phase == .running else { return .terminateNow }
        Store.shared.notice = SettingsWindow.closesAfterTest
        SettingsWindow.shared.show()
        waitForTest = SelfTest.shared.$phase.filter { $0 != .running }.first().sink { _ in
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    private var waitForTest: AnyCancellable?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return true
    }
}

/// Ziele der Menübefehle – in Mountpoint öffnen sie die Einstellungs-App, in ihr das Fenster.
@MainActor
final class MenuActions: NSObject {
    @objc func settings() { settingsMode ? SettingsWindow.shared.show() : SettingsLauncher.shared.open() }
    @objc func about() { settingsMode ? SettingsWindow.shared.show(.about) : SettingsLauncher.shared.open(.about) }
}

/// HIG: Einstellungen im App-Menü (⌘,); „Bearbeiten“ für Kopieren/Einfügen in Textfeldern; ⌘W schließt das Fenster.
/// In Mountpoint (ohne sichtbare Menüleiste) liefert es nur die Tastenkürzel.
@MainActor
func buildMainMenu(_ actions: MenuActions) {
    let main = NSMenu()
    func menu(_ title: String, _ items: [NSMenuItem]) {
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = m
        main.addItem(holder)
    }
    func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil, mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }
    // ⌘W ohne eigenes „Fenster“-Menü (Nutzerwunsch): verstecktes Element, das Kürzel bleibt
    let close = item(loc("Close"), #selector(NSWindow.performClose(_:)), "w")
    close.isHidden = true
    close.allowsKeyEquivalentWhenHidden = true
    menu("Mountpoint", [
        item(loc("About Mountpoint"), #selector(MenuActions.about), "", target: actions),
        .separator(),
        item(loc("Settings…"), #selector(MenuActions.settings), ",", target: actions),
        .separator(),
        item(settingsMode ? loc("Hide Settings") : loc("Hide Mountpoint"), #selector(NSApplication.hide(_:)), "h"),
        item(settingsMode ? loc("Quit Settings") : loc("Quit Mountpoint"), #selector(NSApplication.terminate(_:)), "q"),
        close,
    ])
    menu(loc("Edit"), [
        item(loc("Undo"), Selector(("undo:")), "z"),
        item(loc("Redo"), Selector(("redo:")), "z", mods: [.command, .shift]),
        .separator(),
        item(loc("Cut"), #selector(NSText.cut(_:)), "x"),
        item(loc("Copy"), #selector(NSText.copy(_:)), "c"),
        item(loc("Paste"), #selector(NSText.paste(_:)), "v"),
        item(loc("Select All"), #selector(NSText.selectAll(_:)), "a"),
    ])
    NSApp.mainMenu = main
}
