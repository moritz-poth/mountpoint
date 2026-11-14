import AppKit
import SwiftUI

/// Meldung im Mountpoint-Stil (schwebendes Fenster mit OK) statt NSAlert; eine neue ersetzt die offene.
@MainActor
enum Message {
    private static var panel: NSPanel?

    /// `list` erscheint als Aufzählung zwischen `text` und `footer`.
    static func show(_ title: String, _ text: String, list: [String] = [], footer: String = "") {
        panel?.close()
        panel = showPanel(MessageView(title: title, text: text, list: list, footer: footer, dark: Store.shared.dark) { panel?.close(); panel = nil })
    }
}

struct MessageView: View {
    let title: String
    let text: String
    var list: [String] = []
    var footer = ""
    let dark: Bool
    let ok: () -> Void

    var body: some View {
        let t = Theme(dark: dark)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text(title).font(.mono(15, semibold: true)).foregroundColor(t.text).fixedSize(horizontal: false, vertical: true)
            }
            Text(text).font(.mono(12)).foregroundColor(t.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if !list.isEmpty { bullets(t) }
            if !footer.isEmpty {
                Text(footer).font(.mono(12)).foregroundColor(t.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("OK", action: ok)
                    .buttonStyle(FerryButtonStyle(theme: t, primary: true, height: 32))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 520)
        .cardFrame(t)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// Ab mehr als 10 Einträgen scrollt die Liste, damit das Fenster auf den Bildschirm passt.
    @ViewBuilder private func bullets(_ t: Theme) -> some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(list, id: \.self) { v in
                Text("• " + v).font(.mono(12)).foregroundColor(t.text)
                    .lineLimit(1).truncationMode(.middle).frame(height: Self.row, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        if list.count > 10 {
            ScrollView { rows }.frame(height: Self.row * 10).thinScroller(dark: dark)
        } else {
            rows
        }
    }
    private static let row: CGFloat = 19
}
