import SwiftUI

/// Rückfragen erscheinen im Panel selbst: Systemdialoge würden das Panel schließen.
enum Dialog {
    case newProject
    case rename(Project)
    case deleteProject(Project)
    case removeWorkspace(Workspace)
    case noAvidFolder(URL, UUID?)
    case error(String)
    case networkInfo
}

private let titleCapHeight = NSFont(name: "HelveticaNeue-Light", size: 26)?.capHeight ?? 18.6

struct Panel: View {
    @ObservedObject var store: Store
    @ObservedObject private var updater = Updater.shared
    @State private var hideUpdate = false
    let hold: (Bool) -> Void
    /// aufgeklappte Projekte, über Neustarts gemerkt
    @State private var expanded = Set((UserDefaults.standard.stringArray(forKey: "expanded") ?? []).compactMap(UUID.init(uuidString:)))
    @State private var dialog: Dialog?
    /// Ordnerauswahl offen; Wert = Zielprojekt
    @State private var picking: UUID?? = nil
    @ObservedObject private var settingsWindow = SettingsWindow.shared
    @State private var text = ""
    @State private var flag = true
    @FocusState private var focused: Bool

    var body: some View {
        // the setting decides, not what the popover window happens to report (it lagged behind when switching)
        let t = Theme(dark: store.dark)
        // ZStack statt overlay: das Panel wächst mit, wenn die Rückfrage größer ist als der Inhalt
        ZStack {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("MOUNTPOINT")
                    .font(.custom("HelveticaNeue-Light", size: 26))
                    .tracking(2.5)
                    .foregroundColor(t.text)
                Spacer()
                // öffnet das Einstellungsfenster (Panel bleibt offen); gefüllt, solange es offen ist
                Button { SettingsWindow.shared.show() } label: {
                    Image(systemName: settingsWindow.isOpen ? "gearshape.fill" : "gearshape").font(.system(size: 15)).foregroundColor(t.muted)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Mitte des Zahnrads auf Mitte der Großbuchstaben (Titel hat keine Unterlängen)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + titleCapHeight / 2 }
                .keyboardShortcut(",", modifiers: .command)
                .help(Text("Settings"))
                .accessibilityLabel(Text("Settings"))
            }

            if let notice = store.notice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundColor(t.partial)
                    Text(notice).font(.mono(11)).foregroundColor(t.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.notice = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(t.muted)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Close"))
                }
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.line, lineWidth: 1))
            }

            if let release = updater.available, !hideUpdate || updater.state == .installing {
                updateBanner(release, t)
            }

            if let target = picking {
                // startet dort, wo zuletzt gewählt wurde: mehrere Workspaces liegen meist nebeneinander
                FolderBrowser(theme: t, start: store.lastFolder, hold: hold, onChoose: { url in
                    picking = nil
                    store.lastFolder = url.deletingLastPathComponent()
                    chosen(url, for: target)
                }, onCancel: { picking = nil })
            } else {
                content(t)
            }
        }
        .padding(24)
        .frame(width: 400, alignment: .top)
            if let d = dialog {
                t.background.opacity(0.8).contentShape(Rectangle()).onTapGesture {}
                card(d, t).padding(20)
            }
        }
        .frame(width: 400)
        .background(t.background)
        .environment(\.colorScheme, store.dark ? .dark : .light)
        .environment(\.locale, store.locale)
        .onChange(of: expanded) { UserDefaults.standard.set($0.map(\.uuidString), forKey: "expanded") }
        // settings are saved right away; reopening the panel always starts on the main page
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            picking = nil
        }
    }

    @ViewBuilder private func content(_ t: Theme) -> some View {
            if store.library.workspaces.isEmpty && store.library.projects.isEmpty {
                Text("Add a folder to mount it as its own volume – e.g. the folder that contains “Avid MediaFiles”.")
                    .font(.mono(12))
                    .foregroundColor(t.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(store.library.projects) { projectSection($0, t) }

            let loose = store.workspaces(in: nil)
            if !loose.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: store.library.projects.isEmpty ? loc("Workspaces") : loc("No project"), theme: t)
                    ForEach(loose) { row($0, t) }
                }
            }

            Rectangle().fill(t.line).frame(height: 1)

            HStack {
                Dropdown(title: Text("Add…"), theme: t) {
                    Button("Add workspace…") { addWorkspace(to: nil) }
                    Button("New project…") { show(.newProject) }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(FerryButtonStyle(theme: t))
            }
    }

    private func updateBanner(_ release: Release, _ t: Theme) -> some View {
        let version = String(release.tag.dropFirst(release.tag.hasPrefix("v") ? 1 : 0))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 12)).foregroundColor(t.online)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mountpoint \(version) is available.").font(.mono(11, semibold: true)).foregroundColor(t.text)
                    Text(release.manual
                         ? "This update has to be installed by hand: download it from GitHub, quit Mountpoint and replace the app in the Applications folder."
                         : "Installing restarts Mountpoint. Mounted volumes are ejected and mounted again – quit Media Composer first.")
                        .font(.mono(11)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
                    if case .failed(let message) = updater.state {
                        Text(message).font(.mono(11)).foregroundColor(t.partial).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if updater.state != .installing {
                    Button { hideUpdate = true } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(t.muted)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Close"))
                }
            }
            HStack(spacing: 10) {
                if updater.state == .installing {
                    ProgressView().controlSize(.small)
                    Text("Installing update…").font(.mono(11)).foregroundColor(t.muted)
                } else if release.manual {
                    Button("Download from GitHub") { NSWorkspace.shared.open(release.safePage) }
                        .buttonStyle(FerryButtonStyle(theme: t, primary: true))
                } else {
                    Button("Install update") { updater.install() }
                        .buttonStyle(FerryButtonStyle(theme: t, primary: true))
                    Button("What’s new") { NSWorkspace.shared.open(release.safePage) }
                        .buttonStyle(FerryButtonStyle(theme: t))
                }
            }
            .padding(.leading, 22)
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.line, lineWidth: 1))
    }

    // MARK: Projekte

    private func projectSection(_ p: Project, _ t: Theme) -> some View {
        let items = store.workspaces(in: p.id)
        let state = store.state(of: p.id)
        let open = expanded.contains(p.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    if open { expanded.remove(p.id) } else { expanded.insert(p.id) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(t.muted)
                            .frame(width: 8)
                        dot(state, t)
                        SectionTitle(title: p.name, theme: t)
                        if p.mountAtLaunch {
                            Text("AT LAUNCH")
                                .font(.mono(10, semibold: true))
                                .tracking(0.5)
                                .foregroundColor(t.faint)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(t.line, lineWidth: 1))
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(p.name))

                MoreMenu(theme: t) {
                    Toggle("Mount at app launch", isOn: Binding(get: { p.mountAtLaunch }, set: { _ in store.toggleMountAtLaunch(p) }))
                    Button("Add workspace…") { addWorkspace(to: p.id) }
                    Button("Clear error messages") { store.clearErrors(in: p.id) }
                        .disabled(!items.contains { store.errors[$0.id] != nil })
                    Divider()
                    Button("Rename…") { show(.rename(p), text: p.name) }
                    Button("Delete project…") { show(.deleteProject(p)) }
                }
                let ejecting = items.contains { store.busy.contains($0.id) && store.mounted.contains($0.id) }
                Button(state == .busy ? (ejecting ? "Ejecting…" : "Mounting…") : state == .all ? "Eject" : "Mount") {
                    state == .all ? store.unmountAll(p.id) : store.mountAll(p.id)
                }
                .buttonStyle(FerryButtonStyle(theme: t, primary: state != .all))
                .disabled(items.isEmpty || state == .busy)
            }
            if open {
                if items.isEmpty {
                    Text("No workspaces yet.").font(.mono(12)).foregroundColor(t.faint).padding(.leading, 18)
                }
                ForEach(items) { row($0, t) }
            }
        }
    }

    /// Form trägt den Zustand mit (nicht nur die Farbe): voll = eingehängt, halb = teilweise/Problem, Ring = nicht eingehängt
    private func dot(_ state: MountState, _ t: Theme) -> some View {
        ZStack {
            switch state {
            case .all: Circle().fill(t.online)
            case .none: Circle().strokeBorder(t.faint, lineWidth: 1.5)
            default:
                Circle().strokeBorder(t.partial, lineWidth: 1.5)
                Circle().fill(t.partial).mask(HStack(spacing: 0) { Rectangle(); Color.clear })
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityElement()
        .accessibilityLabel(state == .all ? Text("Mounted") : state == .none ? Text("Not mounted") : Text("Partly mounted or problem"))
    }

    // MARK: Workspaces

    private func row(_ w: Workspace, _ t: Theme) -> some View {
        let isMounted = store.mounted.contains(w.id)
        let isBusy = store.busy.contains(w.id)
        let error = store.errors[w.id]
        return HStack(spacing: 10) {
            dot(isMounted && error == nil ? .all : isBusy || error != nil ? .partial : .none, t)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.name)
                    .font(.mono(13, semibold: true))
                    .foregroundColor(t.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(error ?? w.path)
                    .font(.mono(11))
                    .foregroundColor(error == nil ? t.faint : t.error)
                    .lineLimit(error == nil ? 1 : nil)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(error ?? w.path)
            }
            Spacer(minLength: 8)
            if error != nil {
                Button { store.clearError(w) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(t.muted)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Clear error message"))
                .accessibilityLabel(Text("Clear error message"))
            }
            MoreMenu(theme: t) {
                Menu("Move to project") {
                    ForEach(store.library.projects) { p in
                        Button(p.name) { store.move(w, to: p.id) }.disabled(w.project == p.id)
                    }
                    if !store.library.projects.isEmpty { Divider() }
                    Button("No project") { store.move(w, to: nil) }.disabled(w.project == nil)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: isMounted ? w.volumePath : w.path))
                }
                Divider()
                Button("Remove workspace…") { show(.removeWorkspace(w)) }
            }
            Button(isBusy ? (isMounted ? "Ejecting…" : "Mounting…") : isMounted ? "Eject" : "Mount") {
                isMounted ? store.unmount(w) : store.mount(w)
            }
            .buttonStyle(FerryButtonStyle(theme: t, primary: !isMounted))
            .disabled(isBusy)
        }
        .padding(.leading, 18)
    }

    private func addWorkspace(to project: UUID?) {
        picking = .some(project)
    }

    private func chosen(_ url: URL, for project: UUID?) {
        if let project { expanded.insert(project) }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Avid MediaFiles").path) {
            store.add(url, to: project)
        } else {
            show(.noAvidFolder(url, project))
        }
    }

    // MARK: Rückfragen

    private func show(_ d: Dialog, text: String = "") {
        self.text = text
        flag = true
        dialog = d
        focused = true
    }

    private func card(_ d: Dialog, _ t: Theme) -> some View {
        let title: String
        var info: String?
        var ok = loc("OK")
        var needsText = false
        var checkbox = false
        var secondary: String?
        var cancel = true
        switch d {
        case .newProject:
            title = loc("New project")
            ok = loc("Create")
            needsText = true
        case .rename:
            title = loc("Rename project")
            needsText = true
        case .deleteProject(let p):
            title = loc("Delete project “\(p.name)”?")
            checkbox = !store.workspaces(in: p.id).isEmpty
            info = checkbox && flag
                ? loc("Its volumes are ejected and its workspaces removed. No files are touched.")
                : loc("Its workspaces stay and move to “No project”. No files are touched.")
            ok = loc("Delete")
        case .removeWorkspace(let w):
            title = loc("Remove workspace “\(w.name)”?")
            info = loc("The volume is ejected. The folder and its files are not touched.")
            ok = loc("Remove")
        case .noAvidFolder(let url, _):
            title = loc("No “Avid MediaFiles” folder in “\(url.lastPathComponent)”.")
            info = loc("Media Composer only finds media if “Avid MediaFiles” lies directly in the mounted folder. Create “Avid MediaFiles/MXF” in it?")
            ok = loc("Create")
            secondary = loc("Add only")
        case .error(let message):
            title = message
            cancel = false
        case .networkInfo:
            title = loc("Mounted as network drive")
            info = loc("The Finder will warn that deleted items “will be deleted immediately” – that is right: Mountpoint volumes have no Trash. Applies the next time a workspace is mounted.")
            cancel = false
        }
        let name = text.trimmingCharacters(in: .whitespaces)

        return VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.mono(13, semibold: true))
                .foregroundColor(t.text)
                .fixedSize(horizontal: false, vertical: true)
            if let info {
                Text(info).font(.mono(12)).foregroundColor(t.muted).fixedSize(horizontal: false, vertical: true)
            }
            if needsText {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.mono())
                    .foregroundColor(t.text)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.line, lineWidth: 1))
                    .focused($focused)
                    .onSubmit { if !name.isEmpty { confirm(d, name) } }
            }
            if checkbox {
                SwitchRow(title: "Also remove its workspaces", on: flag, theme: t) { flag.toggle() }
            }
            HStack(spacing: 10) {
                Spacer()
                if cancel {
                    Button("Cancel") { dialog = nil }
                        .buttonStyle(FerryButtonStyle(theme: t))
                        .keyboardShortcut(.cancelAction)
                }
                if let secondary {
                    Button(secondary) { confirm(d, name, secondary: true) }
                        .buttonStyle(FerryButtonStyle(theme: t))
                }
                Button(ok) { confirm(d, name) }
                    .buttonStyle(FerryButtonStyle(theme: t, primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(needsText && name.isEmpty)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 10).fill(t.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func confirm(_ d: Dialog, _ name: String, secondary: Bool = false) {
        dialog = nil
        switch d {
        case .newProject:
            store.addProject(name)
        case .rename(let p):
            store.rename(p, to: name)
        case .deleteProject(let p):
            store.delete(p, removeWorkspaces: flag)
        case .removeWorkspace(let w):
            store.remove(w)
        case .noAvidFolder(let url, let project):
            if !secondary {
                do { try createAvidFolders(in: url) } catch {
                    show(.error(loc("“Avid MediaFiles” could not be created: \(error.localizedDescription)")))
                    return
                }
            }
            store.add(url, to: project)
        case .error, .networkInfo:
            break
        }
    }
}
