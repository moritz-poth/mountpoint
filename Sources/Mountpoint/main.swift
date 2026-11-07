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
    private var panelBeforeHide = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        var arch = utsname()
        uname(&arch)
        let machine = withUnsafeBytes(of: arch.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        Log.write("Mountpoint \(Updater.current) started (\(machine), macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts") ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let store = Store.shared
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
        VolumeGuard.shared.hold = { [weak self] on in self?.hold(on) }
        SettingsWindow.shared.hold = { [weak self] on in self?.hold(on) }
        SettingsWindow.shared.beforeHide = { [weak self] in self?.panelBeforeHide = self?.popover.isShown ?? false }
        SettingsWindow.shared.afterUnhide = { [weak self] in
            guard let self, self.panelBeforeHide, !self.popover.isShown, let button = self.item.button else { return }
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        VolumeGuard.shared.start()
        Welcome.showIfNeeded { Consent.showIfNeeded() }
        // App-Menü (sichtbar, solange die Einstellungen offen sind – dann ist Mountpoint eine normale App)
        buildMenu()
        language = store.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.buildMenu() }
        }
        // Einstellungen und Panel gehen gemeinsam in den Hintergrund und kommen gemeinsam zurück
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appResigned() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appActivated() }
        }
        Updater.shared.start()
    }

    /// Beim Beenden auswerfen; was noch benutzt wird, bleibt eingehängt – und das sagen wir.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Log.write("quit")
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
        return .terminateNow
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
        guard SettingsWindow.shared.isOpen, !SettingsWindow.shared.reactivating else { return }
        panelBeforeDeactivate = popover.isShown
        if popover.isShown { popover.performClose(nil) }
    }

    private func appActivated() {
        guard SettingsWindow.shared.isOpen, !SettingsWindow.shared.reactivating else { return }
        if panelBeforeDeactivate, !popover.isShown, let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        panelBeforeDeactivate = false
        SettingsWindow.shared.front()
    }

    /// Dock-Symbol angeklickt (nur sichtbar, solange die Einstellungen offen sind)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return true
    }

    @objc private func showSettings() { SettingsWindow.shared.show() }
    @objc private func showAbout() { SettingsWindow.shared.show(.about) }

    /// HIG: Einstellungen im App-Menü (⌘,); „Bearbeiten“ für Kopieren/Einfügen in Textfeldern; ⌘W schließt das Fenster.
    private func buildMenu() {
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
        menu("Mountpoint", [
            item(loc("About Mountpoint"), #selector(showAbout), "", target: self),
            .separator(),
            item(loc("Settings…"), #selector(showSettings), ",", target: self),
            .separator(),
            item(loc("Hide Mountpoint"), #selector(NSApplication.hide(_:)), "h"),
            item(loc("Quit Mountpoint"), #selector(NSApplication.terminate(_:)), "q"),
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
        menu(loc("Window"), [item(loc("Close"), #selector(NSWindow.performClose(_:)), "w")])
        NSApp.mainMenu = main
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
UserDefaults.standard.set([UserDefaults.standard.string(forKey: "language") ?? "en"], forKey: "AppleLanguages")

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
