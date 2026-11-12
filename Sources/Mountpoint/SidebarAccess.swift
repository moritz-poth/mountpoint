import AppKit
import SwiftUI

/// „In der Finder-Seitenleiste zeigen“ setzt voraus, dass Mountpoint Cleanup Festplattenvollzugriff hat – ohne sie
/// blieben alte Einträge ausgeworfener Volumes in der Liste (Sidebar.runCleanup). Fehlt er, wenn die Einstellung an ist
/// (beim Start, nach dem Einschalten, nach jedem Update – macOS schaltet die Freigabe dann aus), fragt dieses Fenster:
/// Systemeinstellungen öffnen (es prüft dann alle 3 s selbst und schließt sich) oder die Seitenleiste ausschalten.
/// Mountpoint selbst liest die geschützte Liste nie – sonst stünde es (ausgeschaltet) mit in der Liste; seinen
/// Vollzugriff aus 1.3.4 entfernt AppDelegate.dropOldAccess.
@MainActor
enum SidebarAccess {
    private static var panel: NSPanel?
    private static var pending: [@MainActor () -> Void] = []
    private static var poll: Timer?
    private static let state = AccessState()
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Mountpoint Cleanup steht nach ihrem ersten Start schon (ausgeschaltet) in der Liste
    static func openSettings() { NSWorkspace.shared.open(settingsURL) }

    /// Beim Start: auf das Ergebnis des Aufräumens warten, dann bei Bedarf fragen
    static func showIfNeeded(then: @escaping @MainActor () -> Void) {
        guard Updater.current != "dev", Store.shared.sidebar else { then(); return }
        var started = false
        let go: @MainActor () -> Void = {
            guard !started else { return }
            started = true
            guard Store.shared.sidebar, defaults.object(forKey: Sidebar.accessKey) as? Bool != true else { then(); return }
            ask(then: then)
        }
        Sidebar.afterCleanup(go)
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { MainActor.assumeIsolated { go() } }   // falls kein Aufräumen kommt
    }

    /// Die Seitenleiste wurde gerade eingeschaltet (Einstellungen, empfohlene Einstellungen): prüfen, sonst fragen
    static func require(then: @escaping @MainActor () -> Void = {}) {
        guard Updater.current != "dev", Store.shared.sidebar else { then(); return }
        if panel != nil { pending.append(then); return }
        Sidebar.checkAccess { ok in ok ? then() : ask(then: then) }
    }

    private static func ask(then: @escaping @MainActor () -> Void) {
        pending.append(then)
        guard panel == nil else { panel?.makeKeyAndOrderFront(nil); return }
        Log.write("sidebar: Mountpoint Cleanup has no Full Disk Access, asking")
        state.waiting = false
        panel = showPanel(SidebarAccessView(state: state) { allow in
            if allow { openSettings(); wait() } else { turnOff() }
        })
    }

    /// Nach dem Öffnen der Systemeinstellungen: alle 3 s mit einem Prüflauf nachsehen
    private static func wait() {
        Log.write("sidebar access: settings opened, waiting")
        state.waiting = true
        poll?.invalidate()
        var checking = false
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !checking, panel != nil else { return }
                checking = true
                Sidebar.checkAccess { ok in
                    checking = false
                    guard ok, panel != nil else { return }
                    Log.write("sidebar access: granted")
                    finish()
                }
            }
        }
    }

    private static func turnOff() {
        Log.write("sidebar access: declined, sidebar turned off")
        Store.shared.sidebar = false
        finish()
    }

    private static func finish() {
        poll?.invalidate(); poll = nil
        panel?.close(); panel = nil
        let next = pending
        pending = []
        next.forEach { $0() }
    }
}

@MainActor
final class AccessState: ObservableObject {
    /// Systemeinstellungen geöffnet, Prüfläufe laufen
    @Published var waiting = false
}

struct SidebarAccessView: View {
    @ObservedObject var state: AccessState
    let answer: (Bool) -> Void
    @ObservedObject private var store = Store.shared

    var body: some View {
        let t = Theme(dark: store.dark)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text("Keep the Finder sidebar tidy")
                    .font(.mono(15, semibold: true)).foregroundColor(t.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Ejected volumes stay in the Finder's sidebar list and come back when the Finder shows all external disks. A small helper, “Mountpoint Cleanup”, deletes Mountpoint's own old entries there at every start. It needs Full Disk Access for this.")
                .font(.mono(12)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
            Text("In System Settings → Privacy & Security → Full Disk Access, switch on “Mountpoint Cleanup”. Only this helper gets the access, and it changes nothing but this list.")
                .font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
            // Platz von Anfang an: das Fenster wächst nicht mit, wenn die Zeile später erscheint
            Text("Waiting for the access – this window closes by itself.")
                .font(.mono(11)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
                .opacity(state.waiting ? 1 : 0)
                .accessibilityHidden(!state.waiting)
            // de/fr: beide Knöpfe nebeneinander sind breiter als das Fenster – dann untereinander
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { decline(t); Spacer(); allow(t) }
                VStack(alignment: .trailing, spacing: 10) { allow(t); decline(t) }.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 10).fill(t.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.line, lineWidth: 1))
        .environment(\.colorScheme, store.dark ? .dark : .light)
    }

    private func decline(_ t: Theme) -> some View {
        Button("Don’t show in the sidebar") { answer(false) }
            .buttonStyle(FerryButtonStyle(theme: t, height: 32))
            .keyboardShortcut(.cancelAction)
    }

    private func allow(_ t: Theme) -> some View {
        Button("Open System Settings") { answer(true) }
            .buttonStyle(FerryButtonStyle(theme: t, primary: true, height: 32))
            .keyboardShortcut(.defaultAction)
    }
}
