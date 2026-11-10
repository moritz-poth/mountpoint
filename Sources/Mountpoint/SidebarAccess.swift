import AppKit
import SwiftUI

/// Einmal (erster Start bzw. erstes Update auf 1.3.4): fehlt Mountpoint der Festplattenvollzugriff, den das Aufräumen
/// der Finder-Seitenleiste braucht (Sidebar.purge), erklären und die Systemeinstellung öffnen. Läuft zwischen dem
/// Willkommens-Fenster und der Frage nach dem Selbsttest.
@MainActor
enum SidebarAccess {
    private static let key = "sidebarAccessAsked"
    private static var panel: NSPanel?
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func showIfNeeded(then: @escaping @MainActor () -> Void) {
        guard Updater.current != "dev", Store.shared.sidebar, !defaults.bool(forKey: key),
              case .failure(let problem) = Sidebar.readList(), problem.noAccess else { then(); return }
        let view = SidebarAccessView { allow in
            defaults.set(true, forKey: key)
            Log.write("sidebar access " + (allow ? "requested" : "declined"))
            if allow { NSWorkspace.shared.open(settingsURL) }
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
    let answer: (Bool) -> Void
    @ObservedObject private var store = Store.shared

    var body: some View {
        let t = Theme(dark: store.dark)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text("Keep the Finder sidebar tidy").font(.mono(15, semibold: true)).foregroundColor(t.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Ejected volumes stay in the Finder's sidebar list and come back when the Finder shows all external disks. With Full Disk Access, Mountpoint deletes its own old entries there at every start.")
                .font(.mono(12)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
            Text("In System Settings → Privacy & Security → Full Disk Access, add Mountpoint with + and switch it on. It takes effect at Mountpoint's next start. Mountpoint only changes this list, never your files.")
                .font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
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
