import AppKit
import SwiftUI

/// Beim ersten Start auf einem Mac und nach jedem Update (einmal je Version): darf Mountpoint einen kurzen Selbsttest
/// machen und das Ergebnis anonym senden? „Jetzt nicht“ fragt erst bei der nächsten Version wieder.
@MainActor
enum Consent {
    private static let key = "selftestAskedFor"
    private static var panel: NSPanel?

    static func showIfNeeded() {
        let version = Updater.current
        guard version != "dev", UserDefaults.standard.string(forKey: key) != version, SelfTest.shared.phase == .idle else { return }
        show()
    }

    static func show() {
        guard panel == nil else { panel?.makeKeyAndOrderFront(nil); return }
        let p = AlertPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: ConsentView { close() }.environment(\.locale, Store.shared.locale))
        host.sizingOptions = .preferredContentSize
        p.contentViewController = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false   // NSPanel verschwindet sonst, sobald eine andere App aktiv ist (Start nach Update, Systemabfrage)
        p.isReleasedWhenClosed = false
        p.setContentSize(host.view.fittingSize)
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    static func answered() { UserDefaults.standard.set(Updater.current, forKey: key) }

    static func close() {
        panel?.close()
        panel = nil
    }
}

struct ConsentView: View {
    let close: () -> Void
    @ObservedObject private var store = Store.shared
    @ObservedObject private var test = SelfTest.shared

    var body: some View {
        let t = Theme(dark: store.dark)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text(title).font(.mono(15, semibold: true)).foregroundColor(t.text).fixedSize(horizontal: false, vertical: true)
            }
            switch test.phase {
            case .idle:
                Text("May Mountpoint run a short self-test on this Mac and send us the result anonymously? It helps us find problems on other systems and macOS versions.")
                    .font(.mono(12)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
                Text("The test uses a test disk of its own and does not touch your workspaces or files. It takes a few minutes. Only system details, test results and an anonymized log are sent – no names of users, folders or drives.")
                    .font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
            case .running:
                ProgressView(value: Double(test.results.count), total: Double(max(test.total, 1)))
                    .tint(t.online)
                Text(test.current.map { String(localized: String.LocalizationValue($0), bundle: languageBundle) } ?? "")
                    .font(.mono(11)).foregroundColor(t.faint).lineLimit(1)
                Text("You can close this window – the test continues and sends its report when it is done.")
                    .font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
            case .done:
                let fail = test.results.filter { $0.status == .fail }.count
                Text("\(test.results.filter { $0.status == .pass }.count) passed, \(fail) failed, \(test.results.filter { $0.status == .skip }.count) skipped")
                    .font(.mono(12, semibold: true)).foregroundColor(t.text)
                switch test.sendOutcome {
                case .sent?: Text("The report was sent. Thank you for helping!").font(.mono(12)).foregroundColor(t.online)
                case .failed(let path)? where !path.isEmpty:
                    Text("The report could not be sent. It is saved in Downloads as “\((path as NSString).lastPathComponent)” – please try again later or send us the file.")
                        .font(.mono(11)).foregroundColor(t.partial).fixedSize(horizontal: false, vertical: true)
                default:
                    Text("The report could not be sent or saved.").font(.mono(11)).foregroundColor(t.partial)
                }
            }
            HStack(spacing: 12) {
                switch test.phase {
                case .idle:
                    Button("Not now") { Consent.answered(); Log.write("self-test declined"); close() }
                        .buttonStyle(FerryButtonStyle(theme: t, height: 32))
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Run self-test") { Consent.answered(); test.autoSend = true; test.start() }
                        .buttonStyle(FerryButtonStyle(theme: t, primary: true, height: 32))
                        .keyboardShortcut(.defaultAction)
                case .running:
                    Spacer()
                    Button("Close") { close() }.buttonStyle(FerryButtonStyle(theme: t, height: 32))
                case .done:
                    Spacer()
                    Button("Close") { test.reset(); close() }
                        .buttonStyle(FerryButtonStyle(theme: t, primary: true, height: 32))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 10).fill(t.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.line, lineWidth: 1))
        .environment(\.colorScheme, store.dark ? .dark : .light)
    }

    private var title: String {
        switch test.phase {
        case .idle: return loc("Help improve Mountpoint")
        case .running: return loc("Self-test running…")
        case .done: return loc("Self-test done")
        }
    }
}
