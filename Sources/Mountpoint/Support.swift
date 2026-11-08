import SwiftUI

/// Selbsttest im Panel: starten, Fortschritt, Ergebnis, Bericht senden oder sichern.
struct SelfTestView: View {
    let theme: Theme
    @ObservedObject var test: SelfTest
    /// Höhe der Fortschrittsliste – im Einstellungsfenster so, dass das Fenster selbst nie scrollt
    var listHeight: CGFloat = 280
    let done: () -> Void
    /// Ergebnis des Sendens (Einstellungen: Toast, bei Erfolg zurück zu „Support“)
    let sent: (Reporter.Outcome) -> Void
    @State private var nas = SelfTest.nasRoot()
    @State private var outcome: Reporter.Outcome?
    @State private var sending = false

    var body: some View {
        let t = theme
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: loc("Self-test"), theme: t)
            switch test.phase {
            case .idle:
                Text("Mountpoint tests mounting, files, warnings and updates on a test disk of its own and sends us an anonymous report. Your workspaces and files are not touched. It takes about 3–5 minutes.")
                    .font(.mono(12)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
                Text("The Finder may ask once whether Mountpoint may control it – please allow it, that tests copying with the Finder.")
                    .font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
                if test.blocked {
                    Text("A self-test is already running – in Mountpoint or in the settings. Wait until it is done.")
                        .font(.mono(11)).foregroundColor(t.partial).fixedSize(horizontal: false, vertical: true)
                }
                if let nas {
                    SwitchRow(title: "Also test on “\((nas as NSString).lastPathComponent)”", on: test.includeNAS, theme: t) { test.includeNAS.toggle() }
                    Text("Creates a test folder on this network share and deletes it afterwards.")
                        .font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
                }
            case .running, .done:
                list(t)
            }
            if case .done = test.phase { summary(t) }
            Rectangle().fill(t.line).frame(height: 1)
            HStack(spacing: 10) {
                Button(test.phase == .running ? "Hide" : "Back", action: done).buttonStyle(FerryButtonStyle(theme: t))
                Spacer()
                switch test.phase {
                case .idle:
                    Button("Start self-test") { outcome = nil; test.start() }
                        .buttonStyle(FerryButtonStyle(theme: t, primary: true)).keyboardShortcut(.defaultAction)
                case .running:
                    ProgressView().controlSize(.small)
                case .done:
                    Button("Save report") { if let r = test.report { outcome = Reporter.save(r, reveal: true) } }
                        .buttonStyle(FerryButtonStyle(theme: t))
                    Button(sending ? "Sending…" : "Send report") { send() }
                        .buttonStyle(FerryButtonStyle(theme: t, primary: true))
                        .disabled(sending || (outcome ?? test.sendOutcome).map { if case .sent = $0 { return true } else { return false } } ?? false)
                }
            }
        }
    }

    private func list(_ t: Theme) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(test.results) { r in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: r.status == .pass ? "checkmark.circle.fill" : r.status == .fail ? "xmark.circle.fill" : "minus.circle")
                                .font(.system(size: 12))
                                .foregroundColor(r.status == .pass ? t.online : r.status == .fail ? t.error : t.faint)
                                .accessibilityLabel(r.status == .pass ? Text("Passed") : r.status == .fail ? Text("Failed") : Text("Skipped"))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: shown(r.title)).font(.mono(12)).foregroundColor(t.text)
                                Text(r.detail).font(.mono(10)).foregroundColor(r.status == .fail ? t.error : t.faint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .id(r.id)
                    }
                    if let current = test.current {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini).frame(width: 12)
                            Text(verbatim: shown(current)).font(.mono(12)).foregroundColor(t.muted)
                        }
                        .id("current")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: listHeight)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.line, lineWidth: 1))
            .onChange(of: test.results.count) { _ in withAnimation { proxy.scrollTo(test.current == nil ? test.results.last?.id : "current", anchor: .bottom) } }
        }
    }

    /// Testnamen übersetzt anzeigen; im Bericht bleiben sie englisch (einheitlich auswertbar).
    private func shown(_ title: String) -> String { String(localized: String.LocalizationValue(title), bundle: languageBundle) }

    private func summary(_ t: Theme) -> some View {
        let pass = test.results.filter { $0.status == .pass }.count
        let fail = test.results.filter { $0.status == .fail }.count
        let skip = test.results.filter { $0.status == .skip }.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(pass) passed, \(fail) failed, \(skip) skipped").font(.mono(12, semibold: true)).foregroundColor(fail > 0 ? t.error : t.text)
            switch outcome ?? test.sendOutcome {
            case .sent?: Text("Report sent – thank you!").font(.mono(11)).foregroundColor(t.online)
            case .saved(let path)?: Text("Saved as “\((path as NSString).lastPathComponent)” in Downloads.").font(.mono(11)).foregroundColor(t.faint)
            case .failed(let path)?:
                Text(path.isEmpty ? loc("The report could not be sent or saved.") : loc("The report could not be sent. It is saved in Downloads as “\((path as NSString).lastPathComponent)” – please try again later or send us the file."))
                    .font(.mono(11)).foregroundColor(t.partial).fixedSize(horizontal: false, vertical: true)
            case nil:
                Text("Only anonymous data is sent: system, test results and the log with user and folder names replaced. Save the report to look at it first.")
                    .font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func send() {
        guard let r = test.report else { return }
        sending = true
        Task { let result = await Reporter.send(r); sending = false; sent(result) }
    }
}

/// „Problem melden“: Beschreibung, optional E-Mail, optional Systeminfo und Log – ohne GitHub-Konto.
struct ProblemView: View {
    let theme: Theme
    var editorHeight: CGFloat = 130
    let done: () -> Void
    /// Ergebnis des Sendens (Einstellungen: Toast, bei Erfolg zurück zu „Support“)
    let sent: (Reporter.Outcome) -> Void
    @State private var text = ""
    @State private var contact = ""
    @State private var attach = true
    @State private var sending = false

    var body: some View {
        let t = theme
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: loc("Report a problem"), theme: t)
            Text("What happened, and what did you expect? Ideas are welcome too. No GitHub account needed.")
                .font(.mono(12)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.mono(12))
                .foregroundColor(t.text)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: editorHeight)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.line, lineWidth: 1))
                .accessibilityLabel(Text("Description"))
            TextField("", text: $contact, prompt: Text("Email for questions (optional)"))
                .textFieldStyle(.plain)
                .font(.mono(12))
                .foregroundColor(t.text)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.line, lineWidth: 1))
            SwitchRow(title: "Attach system info and log file", on: attach, theme: t) { attach.toggle() }
            Text("Anonymized: your user name and folder names are replaced.")
                .font(.mono(11)).foregroundColor(t.faint).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(t.line).frame(height: 1)
            HStack(spacing: 10) {
                Button("Back", action: done).buttonStyle(FerryButtonStyle(theme: t))
                Spacer()
                Button(sending ? "Sending…" : "Send") { send() }
                    .buttonStyle(FerryButtonStyle(theme: t, primary: true))
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func send() {
        let report = Reporter.problem(text: text.trimmingCharacters(in: .whitespacesAndNewlines), contact: contact.trimmingCharacters(in: .whitespaces), attach: attach)
        sending = true
        Task {
            let result = await Reporter.send(report)
            if case .sent = result { text = "" }
            sending = false
            sent(result)
        }
    }
}

/// Kurze Meldung nach dem Senden (Selbsttest, Problem melden): Erfolg 3 s, Fehler 8 s (Dateiname lesbar).
struct Toast: Equatable {
    let text: String
    let ok: Bool

    init(_ outcome: Reporter.Outcome) {
        switch outcome {
        case .sent: (text, ok) = (loc("Sent – thank you!"), true)
        case .failed(let path) where !path.isEmpty:
            (text, ok) = (loc("The report could not be sent. It is saved in Downloads as “\((path as NSString).lastPathComponent)” – please try again later or send us the file."), false)
        default: (text, ok) = (loc("The report could not be sent or saved."), false)
        }
    }
}

extension View {
    /// zeigt `toast` unten über dem Inhalt und blendet ihn nach 3 s (Fehler: 8 s) aus
    func toast(_ toast: Binding<Toast?>, theme t: Theme) -> some View {
        overlay(alignment: .bottom) {
            if let shown = toast.wrappedValue {
                Text(shown.text)
                    .font(.mono(11, semibold: true))
                    .foregroundColor(shown.ok ? t.onPrimary : t.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(shown.ok ? t.online : t.background))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(shown.ok ? Color.clear : t.partial, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + (shown.ok ? 3 : 8)) {
                            if toast.wrappedValue == shown { toast.wrappedValue = nil }
                        }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast.wrappedValue)
    }
}
