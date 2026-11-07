import SwiftUI

/// Rechtliche Hinweise nach GPL-3.0 §5d: Copyright, keine Gewährleistung, Lizenz, Quellcode.
struct AboutView: View {
    let theme: Theme
    /// mit „Fertig“-Knopf (im Panel); im Einstellungsfenster ohne
    var done: (() -> Void)? = nil

    static let repo = URL(string: "https://github.com/moritz-poth/mountpoint")!
    static let gpl = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "MountpointRelease") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        let t = theme
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mountpoint").font(.mono(15, semibold: true)).foregroundColor(t.text)
                    Text("Version \(version)").font(.mono(12)).foregroundColor(t.muted)
                    Text(verbatim: "© 2026 Moritz Poth").font(.mono(12)).foregroundColor(t.muted)
                }
            }

            Text("Mountpoint is free software: you can redistribute and modify it under the terms of the GNU General Public License, version 3 or later.")
                .font(.mono(12)).foregroundColor(t.text).fixedSize(horizontal: false, vertical: true)
            Text("It comes with ABSOLUTELY NO WARRANTY – use at your own risk.")
                .font(.mono(12)).foregroundColor(t.text).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Source code") { NSWorkspace.shared.open(Self.repo) }
                    .buttonStyle(FerryButtonStyle(theme: t))
                Button("License") { openLicense() }
                    .buttonStyle(FerryButtonStyle(theme: t))
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: loc("Third-party"), theme: t)
                Text("JetBrains Mono font – SIL Open Font License 1.1")
                Text("Requires macFUSE, which is not included and has its own license.")
                Text("Avid and Media Composer are trademarks of Avid Technology, Inc. LucidLink is a trademark of LucidLink Corp. Mountpoint is not affiliated with either.")
            }
            .font(.mono(11))
            .foregroundColor(t.faint)
            .fixedSize(horizontal: false, vertical: true)

            if let done {
                Rectangle().fill(t.line).frame(height: 1)
                HStack {
                    Spacer()
                    Button("Done", action: done)
                        .buttonStyle(FerryButtonStyle(theme: t, primary: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Mitgelieferter Lizenztext; ohne ihn (Entwicklungs-Build) die Seite der FSF.
    private func openLicense() {
        if let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(Self.gpl)
        }
    }
}
