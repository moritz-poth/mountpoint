import AppKit
import SwiftUI

/// Ohne macFUSE kann Mountpoint nichts einhängen. Beim Start wartet alles Weitere (Einhängen, Fenster, Selbsttest) auf
/// macFUSE; danach prüft Mountpoint alle 30 s weiter und meldet sich, wenn es fehlt.
@MainActor
enum MacFUSE {
    static let website = URL(string: "https://macfuse.github.io")!
    private static var panel: NSPanel?
    private static var poll: Timer?
    private static var watching: Timer?

    static var installed: Bool { FileManager.default.fileExists(atPath: Mounter.macFUSE) }

    /// `then` erst, wenn macFUSE da ist (sofort, wenn schon installiert)
    static func require(then: @escaping @MainActor () -> Void) {
        guard !installed else { then(); return }
        Log.write("macFUSE missing, waiting for it")
        show()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard installed else { return }
                Log.write("macFUSE found")
                poll?.invalidate(); poll = nil
                close()
                then()
            }
        }
    }

    /// Während Mountpoint läuft: wird macFUSE entfernt, das Fenster wieder zeigen (und schließen, sobald es zurück ist)
    static func watch() {
        watching?.invalidate()
        var was = installed
        watching = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = installed
                defer { was = now }
                if was && !now { Log.write("macFUSE was removed"); show() }
                if !was && now { Log.write("macFUSE is back"); close() }
            }
        }
    }

    private static func show() {
        guard panel == nil else { panel?.makeKeyAndOrderFront(nil); return }
        panel = showPanel(MacFUSEView(dark: Store.shared.dark))
    }

    private static func close() {
        panel?.close()
        panel = nil
    }
}

struct MacFUSEView: View {
    let dark: Bool

    var body: some View {
        let t = Theme(dark: dark)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text("Mountpoint needs macFUSE").font(.mono(15, semibold: true)).foregroundColor(t.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("macFUSE lets Mountpoint mount folders as their own volumes. It is free, not included with Mountpoint and has its own license. Install it from its website – Mountpoint notices it and continues on its own.")
                .font(.mono(12)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
            Text("On Macs with Apple silicon, macOS may ask you to allow macFUSE’s system extension under System Settings → Privacy & Security and to restart the Mac.")
                .font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(FerryButtonStyle(theme: t, height: 32))
                Spacer()
                Button("Open the macFUSE website") { NSWorkspace.shared.open(MacFUSE.website) }
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
}

/// Schwebendes Hinweisfenster genau in der Mitte des Bildschirms (Willkommen, Einstellungen, Freigabe, Selbsttest-Frage)
@MainActor
func showPanel<V: View>(_ view: V) -> NSPanel {
    let p = AlertPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingController(rootView: view.environment(\.locale, Store.shared.locale))
    host.sizingOptions = .preferredContentSize
    p.contentViewController = host
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = .floating
    p.hidesOnDeactivate = false   // NSPanel verschwindet sonst, sobald eine andere App aktiv ist
    p.isReleasedWhenClosed = false
    p.setContentSize(host.view.fittingSize)
    // nicht center(): das setzt das Fenster ins obere Drittel, und jedes Fenster säße je nach Höhe woanders
    if let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
        p.setFrameOrigin(NSPoint(x: (screen.midX - p.frame.width / 2).rounded(), y: (screen.midY - p.frame.height / 2).rounded()))
    }
    NSApp.activate(ignoringOtherApps: true)
    p.makeKeyAndOrderFront(nil)
    return p
}
