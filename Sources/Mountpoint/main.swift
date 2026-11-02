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
    private var holds = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        watch = store.$mounted.sink { [weak self] m in
            self?.item.button?.image = menuBarIcon(mounted: !m.isEmpty)
        }
        store.mountAtLaunch()
        VolumeGuard.shared.start()
    }

    /// Beim Neustart wegen Sprachwechsel bleiben die Volumes eingehängt.
    static var relaunching = false

    func applicationWillTerminate(_ notification: Notification) {
        if !AppDelegate.relaunching { Store.shared.unmountAllOnQuit() }
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
    private func hold(_ on: Bool) {
        holds = max(0, holds + (on ? 1 : -1))
        popover.behavior = holds > 0 ? .applicationDefined : .transient
    }
}

/// Icon N01 (assets/menubar.svg) als Vorlage für die Menüleiste; eingehängt = Laufwerk gefüllt.
func menuBarIcon(mounted: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        // Raster wie im SVG: viewBox 4 6 92 92 → 18 pt
        let s = 18.0 / 92.0
        let t = NSAffineTransform()
        t.scale(by: s)
        t.translateX(by: -4, yBy: -6)
        t.concat()
        NSColor.black.set()

        let folder = NSBezierPath()
        folder.move(to: NSPoint(x: 26, y: 45))
        folder.line(to: NSPoint(x: 26, y: 26))
        folder.line(to: NSPoint(x: 45.2, y: 26))
        folder.line(to: NSPoint(x: 50.2, y: 32))
        folder.line(to: NSPoint(x: 74, y: 32))
        folder.line(to: NSPoint(x: 74, y: 45))
        folder.lineWidth = 7
        folder.lineCapStyle = .butt
        folder.lineJoinStyle = .round
        folder.stroke()

        let drive = NSBezierPath(roundedRect: NSRect(x: 14, y: 54, width: 72, height: 22), xRadius: 6, yRadius: 6)
        let led = NSBezierPath(ovalIn: NSRect(x: 74 - 3.5, y: 65 - 3.5, width: 7, height: 7))
        if mounted {
            // gefüllt, LED ausgestanzt
            let outer = NSBezierPath(roundedRect: NSRect(x: 10.5, y: 50.5, width: 79, height: 29), xRadius: 9.5, yRadius: 9.5)
            outer.append(led)
            outer.windingRule = .evenOdd
            outer.fill()
        } else {
            drive.lineWidth = 7
            drive.stroke()
            led.fill()
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
