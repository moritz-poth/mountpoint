import AppKit
import SwiftUI

/// Shown once, centered on screen, until the user confirms it: Finder's delete warning and the disclaimer.
@MainActor
enum Welcome {
    private static let key = "welcomeConfirmed"
    private static var panel: NSPanel?

    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let view = WelcomeView(dark: Store.shared.dark) {
            UserDefaults.standard.set(true, forKey: key)
            panel?.close()
            panel = nil
        }
        let p = AlertPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        p.contentViewController = NSHostingController(rootView: view)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.setContentSize(p.contentViewController!.view.fittingSize)
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
}

struct WelcomeView: View {
    let dark: Bool
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
            section(t, "Deleting in the Finder",
                    "Workspaces are mounted as network drives, so Media Composer Enterprise creates its own “<computer name>.1” folder. For network drives the Finder warns that items “will be deleted immediately”.\n\nWith Mountpoint that is not true: what you delete in the Finder goes to the Trash. “Put Back” is not available – drag items back by hand. Deleting with other apps, e.g. Terminal or Media Composer, is permanent.")
            section(t, "Use at your own risk",
                    "Mountpoint is free software and comes without any warranty. You use it at your own risk. The author is not liable for data loss or any other damage. Always keep a backup of your media.")
            HStack {
                Spacer()
                Button("I understand", action: confirm)
                    .buttonStyle(FerryButtonStyle(theme: t, primary: true, height: 32))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 520)
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
