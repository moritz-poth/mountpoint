import AppKit
import SwiftUI

/// Einmal nach der ersten Installation (nach macFUSE und dem Willkommen): empfohlene Einstellungen, alle vorausgewählt.
/// „Weiter“ übernimmt sie; die Seitenleiste braucht danach noch den Vollzugriff von Mountpoint Cleanup (SidebarAccess).
/// Wer von einer älteren Version kommt, hat schon eingestellt und sieht das Fenster nicht.
@MainActor
enum Setup {
    private static let key = "setupDone"
    private static var panel: NSPanel?

    /// `fresh`: das Willkommen war bei diesem Start noch nicht bestätigt (erste Installation)
    static func showIfNeeded(fresh: Bool, then: @escaping @MainActor () -> Void) {
        guard !defaults.bool(forKey: key) else { then(); return }
        guard fresh else { defaults.set(true, forKey: key); then(); return }
        let choice = SetupChoice()
        panel = showPanel(SetupView(choice: choice) {
            defaults.set(true, forKey: key)
            panel?.close()
            panel = nil
            let store = Store.shared
            Log.write("setup: launch at login \(choice.login ? "on" : "off"), sidebar \(choice.sidebar ? "on" : "off"), network \(choice.network ? "on" : "off")")
            if store.launchAtLogin != choice.login { store.setLaunchAtLogin(choice.login) }
            if store.network != choice.network { store.network = choice.network }
            if store.sidebar != choice.sidebar { store.sidebar = choice.sidebar }
            SidebarAccess.require(then: then)
        })
    }
}

@MainActor
final class SetupChoice: ObservableObject {
    @Published var login = true
    @Published var sidebar = true
    @Published var network = true
}

struct SetupView: View {
    @ObservedObject var choice: SetupChoice
    let done: () -> Void
    @ObservedObject private var store = Store.shared

    var body: some View {
        let t = Theme(dark: store.dark)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text("Recommended settings").font(.mono(15, semibold: true)).foregroundColor(t.text)
            }
            Text("Mountpoint works best with these settings. You can change them any time in the settings.")
                .font(.mono(12)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
            SwitchRow(title: "Launch at login", on: choice.login, theme: t) { choice.login.toggle() }
            note("Starts Mountpoint when you log in, so projects set to “Mount at app launch” are ready right away.", t)
            SwitchRow(title: "Show in the Finder sidebar", on: choice.sidebar, theme: t) { choice.sidebar.toggle() }
            note("Mounted workspaces appear under “Locations”, like your other drives, and disappear again when they are ejected.", t)
            SwitchRow(title: "Mount as network drive", on: choice.network, theme: t) { choice.network.toggle() }
            note("For collaboration with Avid Media Composer Enterprise: it then creates a “<computer name>.1” folder instead of “1”. Turn off “filter network drives” in Media Composer’s Media Creation settings. Applies the next time a workspace is mounted.", t)
            HStack {
                Spacer()
                Button("Continue", action: done)
                    .buttonStyle(FerryButtonStyle(theme: t, primary: true, height: 32))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(26)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 10).fill(t.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.line, lineWidth: 1))
        .environment(\.colorScheme, store.dark ? .dark : .light)
    }

    private func note(_ text: LocalizedStringKey, _ t: Theme) -> some View {
        Text(text).font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
    }
}
