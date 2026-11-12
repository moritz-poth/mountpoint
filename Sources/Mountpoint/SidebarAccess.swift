import AppKit
import SwiftUI

/// Einmal: fehlt Mountpoint Cleanup der Festplattenvollzugriff, den das Aufräumen der Finder-Seitenleiste braucht
/// (Sidebar.runCleanup), erklären und die Systemeinstellung öffnen. Hat Mountpoint selbst noch Vollzugriff (bis 1.3.4
/// erbeten), einmal bitten, ihn auszuschalten – eine App kann ihn sich nicht selbst entziehen. Läuft zwischen dem
/// Willkommens-Fenster und der Frage nach dem Selbsttest.
@MainActor
enum SidebarAccess {
    private static let key = "cleanupAccessAsked", ownKey = "ownAccessRevokeAsked"
    private static var panel: NSPanel?
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Mountpoint Cleanup steht nach seinem ersten Start schon (ausgeschaltet) in der Liste
    static func openSettings() { NSWorkspace.shared.open(settingsURL) }

    static func showIfNeeded(then: @escaping @MainActor () -> Void) {
        guard Updater.current != "dev", Store.shared.sidebar else { then(); return }
        var started = false
        let go: @MainActor () -> Void = {
            guard !started else { return }
            started = true
            show(then: then)
        }
        Sidebar.afterCleanup(go)
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { MainActor.assumeIsolated { go() } }   // falls kein Aufräumen kommt
    }

    private static func show(then: @escaping @MainActor () -> Void) {
        // einmal pro Version: jedes Update ändert die Signatur des Helfers, macOS schaltet seine Freigabe dann aus
        let grant = defaults.object(forKey: Sidebar.accessKey) as? Bool == false && defaults.string(forKey: key) != Updater.current
        // läuft in Mountpoint: gelingt das Lesen, hat Mountpoint selbst noch Vollzugriff
        let revoke: Bool
        if case .success = Sidebar.readList() { revoke = !defaults.bool(forKey: ownKey) } else { revoke = false }
        guard grant || revoke else { then(); return }
        let view = SidebarAccessView(grant: grant, revoke: revoke) { allow in
            if grant { defaults.set(Updater.current, forKey: key) }
            if revoke { defaults.set(true, forKey: ownKey) }
            Log.write("sidebar access " + (allow ? "settings opened" : "declined") + (grant ? ", helper" : "") + (revoke ? ", revoke own" : ""))
            if allow { openSettings() }
            panel?.close()
            panel = nil
            then()
        }
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
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
}

struct SidebarAccessView: View {
    /// Mountpoint Cleanup fehlt der Zugriff / Mountpoint selbst hat ihn noch
    let grant: Bool, revoke: Bool
    let answer: (Bool) -> Void
    @ObservedObject private var store = Store.shared

    var body: some View {
        let t = Theme(dark: store.dark)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text(grant ? "Keep the Finder sidebar tidy" : "Full Disk Access is no longer needed")
                    .font(.mono(15, semibold: true)).foregroundColor(t.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if grant {
                Text("Ejected volumes stay in the Finder's sidebar list and come back when the Finder shows all external disks. A small helper, “Mountpoint Cleanup”, deletes Mountpoint's own old entries there at every start. It needs Full Disk Access for this.")
                    .font(.mono(12)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
                Text("In System Settings → Privacy & Security → Full Disk Access, switch on “Mountpoint Cleanup”. Only this helper gets the access, and it changes nothing but this list.")
                    .font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
            }
            if revoke {
                Text("Mountpoint itself no longer needs Full Disk Access. Please switch it off for “Mountpoint” in the same list.")
                    .font(.mono(grant ? 11 : 12)).foregroundColor(grant ? t.faint : t.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button("Not now") { answer(false) }
                    .buttonStyle(FerryButtonStyle(theme: t, height: 32))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open System Settings") { answer(true) }
                    .buttonStyle(FerryButtonStyle(theme: t, primary: true, height: 32))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 10).fill(t.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.line, lineWidth: 1))
        .environment(\.colorScheme, store.dark ? .dark : .light)
    }
}
