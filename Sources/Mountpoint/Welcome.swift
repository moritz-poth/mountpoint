import AppKit
import SwiftUI

/// Shown once, centered on screen, until the user confirms it: deleting is permanent, and the disclaimer.
@MainActor
enum Welcome {
    // new key whenever the text changes in substance, so everyone reads it once more (v2: no Trash any more)
    private static let key = "welcomeConfirmed2"
    private static var panel: NSPanel?
    static var confirmed: Bool { defaults.bool(forKey: key) }

    /// `then`: danach (sofort, wenn schon bestätigt) – z. B. die Frage nach dem Selbsttest
    static func showIfNeeded(then: @escaping @MainActor () -> Void = {}) {
        guard !defaults.bool(forKey: key) else { then(); return }
        let view = WelcomeView(dark: Store.shared.dark, height: Setup.height) {
            defaults.set(true, forKey: key)
            panel?.close()
            panel = nil
            then()
        }
        panel = showPanel(view)
    }
}

struct WelcomeView: View {
    let dark: Bool
    /// Setup.height: so hoch wie das folgende Fenster „Empfohlene Einstellungen“
    var height: CGFloat = 0
    let confirm: () -> Void

    var body: some View {
        let t = Theme(dark: dark)
        VStack(alignment: .leading, spacing: 20) {
            Text("MOUNTPOINT")
                .font(.custom("HelveticaNeue-Light", size: 26))
                .tracking(2.5)
                .foregroundColor(t.text)
            Text("Mountpoint mounts folders as their own volumes, so Media Composer finds the media in them.")
                .font(.mono(12)).foregroundColor(t.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            section(t, "Deleting is permanent",
                    "What you delete on a Mountpoint volume is gone immediately – there is no Trash, even if the folder lies on a local drive. This applies to the Finder (its warning “will be deleted immediately” is right), Media Composer and every other app. Always keep a backup of your media.")
            section(t, "Use at your own risk",
                    "Mountpoint is free software and comes without any warranty. You use it at your own risk. The author is not liable for data loss or any other damage. Always keep a backup of your media.")
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("I understand", action: confirm)
                    .buttonStyle(FerryButtonStyle(theme: t, primary: true, height: 32))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 520)
        .frame(minHeight: height)
        .background(RoundedRectangle(cornerRadius: 10).fill(t.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.line, lineWidth: 1))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private func section(_ t: Theme, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.mono(13, semibold: true)).foregroundColor(t.text)
            Text(text).font(.mono(12)).foregroundColor(t.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
