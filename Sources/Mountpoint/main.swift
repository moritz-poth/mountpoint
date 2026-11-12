import AppKit
import Combine
import CoreText
import SwiftUI

// Eigenes Statussymbol + Popover statt MenuBarExtra: nur so lässt sich das Panel offen halten (z. B. NAS-Passwort).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var watch: AnyCancellable?
    private var appearance: AnyCancellable?
    private var holds = 0
    private var language: AnyCancellable?
    /// Panel war offen, als Mountpoint (mit offenen Einstellungen) in den Hintergrund ging
    private var panelBeforeDeactivate = false
    private let actions = MenuActions()

    /// Bis 1.3 bat der Selbsttest um die Fernsteuerung des Finders (Kopier-Prüfung, jetzt MountTests.finderCopy). Ein
    /// ausgetauschter Helfer `mirror` erbte sie – einmal zurücksetzen; Mountpoint fragt nie wieder danach.
    static func dropFinderAccess() {
        guard Updater.current != "dev", !defaults.bool(forKey: "finderAccessDropped") else { return }
        DispatchQueue.global().async {
            let (status, out) = (try? Mounter.run("/usr/bin/tccutil", ["reset", "AppleEvents", mainBundleID])) ?? (-1, "not started")
            Log.write("finder access reset: " + (status == 0 ? "ok" : "failed (\(status)) \(out)"))
            if status == 0 { defaults.set(true, forKey: "finderAccessDropped") }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var arch = utsname()
        uname(&arch)
        let machine = withUnsafeBytes(of: arch.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        Log.write("Mountpoint \(Updater.current) started (\(machine), macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts") ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        // vom Disk-Image gestartet: nichts einhängen (die Hilfsprogramme lägen auf dem Image), erst in „Programme“ verschieben
        if runsFromTemporaryPlace() {
            Log.write("started from a temporary place (\(Bundle.main.bundlePath)), asking to move to Applications")
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = loc("Move Mountpoint to the Applications folder")
            a.informativeText = loc("Mountpoint was opened from the disk image or a temporary place. Drag Mountpoint into the Applications folder and open it from there – otherwise it cannot update itself, and your volumes would disappear when the disk image is ejected.")
            a.addButton(withTitle: loc("Quit"))
            a.runModal()
            exit(0)   // nicht terminate: das Beenden würde Store und Seitenleiste erst anfassen
        }
        // Einstellungs-App: Änderungen übernehmen, Aufträge ausführen. Erst zuhören, dann laden (Store.shared liest die
        // Datei): was eine offene Einstellungs-App währenddessen speichert, geht sonst verloren.
        IPC.listen { [weak self] what, info in
            guard let self else { return }
            switch what {
            case "settings": Store.shared.reloadSettings()
            case "library": Store.shared.reloadLibrary()
            case "launchAtLogin": Store.shared.setLaunchAtLogin(info["on"] == "1", request: info["id"] ?? "")
            case "launchAtLoginQuery": Store.shared.publishLaunchAtLogin()
            case "showUpdate":
                // aus der Einstellungs-App: Panel mit dem Update-Hinweis zeigen
                Updater.shared.dismissed = false
                Updater.shared.check(manual: false)
                self.showPanel()
            default: break
            }
        }
        let store = Store.shared
        store.reloadSettings()   // Einstellungen, die vor dem Zuhören geändert wurden
        store.applyAppearance()

        let host = NSHostingController(rootView: Panel(store: store, hold: { [weak self] on in self?.hold(on) }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.setAccessibilityLabel("Mountpoint")
        // Symbol zeigt eingehängt (gefüllt) und Probleme (Punkt) – auch Fehler beim automatischen Einhängen, wenn das Panel zu ist
        // the dot also announces an available update
        watch = store.$mounted.combineLatest(store.$errors, store.$notice, Updater.shared.$available).sink { [weak self] m, e, n, u in
            self?.item.button?.image = menuBarIcon(mounted: !m.isEmpty, problem: !e.isEmpty || n != nil || u != nil)
        }
        // the popover frame (arrow, edge) follows the setting at once, also while open
        appearance = store.$dark.sink { [weak self] dark in
            self?.popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
        store.mountAtLaunch()
        Self.dropFinderAccess()
        VolumeGuard.shared.hold = { [weak self] on in self?.hold(on) }
        SettingsWindow.shared.hold = { [weak self] on in self?.hold(on) }
        VolumeGuard.shared.start()
        Welcome.showIfNeeded { SidebarAccess.showIfNeeded { Consent.showIfNeeded() } }
        // Menü ohne sichtbare Menüleiste (reine Menüleisten-App): liefert ⌘, ⌘C/⌘V (Problem-Formular), ⌘W, ⌘Q
        buildMainMenu(actions)
        language = store.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { if let self { buildMainMenu(self.actions) } }
        }
        store.publishLaunchAtLogin()
        IPC.post("library")   // eine offene Einstellungs-App lädt den aktuellen Stand (z. B. nach dem Beiseitelegen)
        // Einstellungen und Panel gehen gemeinsam in den Hintergrund und kommen gemeinsam zurück
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appResigned() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appActivated() }
        }
        Updater.shared.start()
        // aus der Einstellungs-App gestartet („In Mountpoint zeigen“)
        if CommandLine.arguments.contains("--show-update") {
            Updater.shared.dismissed = false
            Updater.shared.check(manual: false)
            showPanel()
        }
    }

    private var waitForTest: AnyCancellable?

    /// Ein laufender Selbsttest (nach der Zustimmungsfrage) räumt erst auf – sonst blieben Testvolumes zurück.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SelfTest.shared.phase == .running else { quit(); return .terminateNow }
        Log.write("quit waits for the self-test")
        waitForTest = SelfTest.shared.$phase.filter { $0 != .running }.first().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.quit()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// Beim Beenden auswerfen; was noch benutzt wird, bleibt eingehängt – und das sagen wir.
    private func quit() {
        Log.write("quit")
        SettingsLauncher.terminateRunning()
        let still = Store.shared.unmountAllOnQuit()
        Sidebar.removeAll()   // der nächste Start trägt noch eingehängte Volumes wieder ein
        if !still.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.icon = NSApp.applicationIconImage
            a.messageText = loc("Some volumes stay mounted")
            a.informativeText = loc("These volumes are still in use and stay mounted: \(still.joined(separator: ", ")). Quit Media Composer and eject them in the Finder.")
            a.runModal()
        }
    }

    func showPanel() {
        guard !popover.isShown, let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Solange etwas außerhalb des Panels offen ist, schließt es sich nicht bei Klicks daneben.
    private func appResigned() {
        guard SettingsWindow.shared.isOpen else { return }
        panelBeforeDeactivate = popover.isShown
        if popover.isShown { popover.performClose(nil) }
    }

    private func appActivated() {
        guard SettingsWindow.shared.isOpen else { return }
        if panelBeforeDeactivate, !popover.isShown, let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        panelBeforeDeactivate = false
        SettingsWindow.shared.front()
    }

    private func hold(_ on: Bool) {
        holds = max(0, holds + (on ? 1 : -1))
        popover.behavior = holds > 0 ? .applicationDefined : .transient
    }
}

/// Menüleisten-Vorlage „Ordner-Laufwerk“ (wie assets/menubar.svg, 256er Raster): nicht eingehängt = Kontur,
/// eingehängt = gefüllt mit ausgestanzter LED; Problem = Punkt oben rechts.
func menuBarIcon(mounted: Bool, problem: Bool = false) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        // Ausschnitt x 24…232 (208 Einheiten) auf 18 pt, Motivmitte y 138 auf 9 pt
        let s = 18.0 / 208.0
        let t = NSAffineTransform()
        t.translateX(by: 9, yBy: 9)
        t.scale(by: s)
        t.translateX(by: -128, yBy: -138)
        t.concat()
        NSColor.black.set()

        // Körper mit Ordnerreiter, Schräge exakt 45°
        func shape(_ o: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            let (l, top, bodyTop, r, b) = (40 - o, 80 - o, 100 - o, 216 + o, 196 + o)
            let tabEnd = 98 + o * (2.0.squareRoot() - 1)   // die Schräge bleibt beim Erweitern auf derselben 45°-Parallelen
            p.move(to: NSPoint(x: l, y: (bodyTop + b) / 2))
            p.appendArc(from: NSPoint(x: l, y: top), to: NSPoint(x: tabEnd, y: top), radius: 12 + o)
            p.line(to: NSPoint(x: tabEnd, y: top))
            p.line(to: NSPoint(x: tabEnd + bodyTop - top, y: bodyTop))
            p.appendArc(from: NSPoint(x: r, y: bodyTop), to: NSPoint(x: r, y: b), radius: 20 + o)
            p.appendArc(from: NSPoint(x: r, y: b), to: NSPoint(x: l, y: b), radius: 20 + o)
            p.appendArc(from: NSPoint(x: l, y: b), to: NSPoint(x: l, y: top), radius: 20 + o)
            p.close()
            return p
        }
        let led = NSBezierPath(ovalIn: NSRect(x: 180 - 12, y: 164 - 12, width: 24, height: 24))
        if mounted {
            // um die halbe Strichstärke erweitert, damit beide Zustände gleich groß sind; LED ausgestanzt
            let filled = shape(9)
            filled.append(led)
            filled.windingRule = .evenOdd
            filled.fill()
        } else {
            let outline = shape(0)
            outline.lineWidth = 18
            outline.lineJoinStyle = .round
            outline.stroke()
            NSBezierPath(ovalIn: NSRect(x: 180 - 11, y: 164 - 11, width: 22, height: 22)).fill()
        }
        if problem {
            // Warnpunkt oben rechts, über dem Körper
            NSBezierPath(ovalIn: NSRect(x: 197, y: 33, width: 34, height: 34)).fill()
        }
        return true
    }
    image.isTemplate = true
    return image
}

// Sprache der App (Standard Englisch) – muss vor dem ersten übersetzten Text gesetzt sein.
UserDefaults.standard.set([defaults.string(forKey: "language") ?? "en"], forKey: "AppleLanguages")

// Aufräum-App: nur die Finder-Seitenleiste, dann Ende – kein Store, kein Einhängen, keine Oberfläche
if cleanupMode {
    _ = NSApplication.shared   // bei LaunchServices angemeldet, sonst wartet openApplication auf sie
    Sidebar.runCleanup(arguments: CommandLine.arguments)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if settingsMode {
        // Einstellungs-App: normale App (Dock, ⌘-Tab, Menüleiste), nur das Einstellungsfenster
        let delegate = SettingsAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
