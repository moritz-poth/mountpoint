import SwiftUI

/// Ordnerauswahl im Design der App. Oberste Ebene: eingehängte Laufwerke + „Mit Server verbinden“.
struct FolderBrowser: View {
    let theme: Theme
    let start: URL?
    /// hält das Panel offen, während macOS z. B. nach dem NAS-Passwort fragt
    let hold: (Bool) -> Void
    let onChoose: (URL) -> Void
    let onCancel: () -> Void

    struct Item: Identifiable {
        let url: URL
        let name: String
        let avid: Bool
        var id: URL { url }
    }

    @State private var current: URL?
    @State private var items: [Item] = []
    @State private var loading = false
    @State private var readError: String?
    @State private var server = "smb://"
    @State private var connecting = false
    @State private var error: String?
    @State private var newFolder: String?
    @State private var withAvid = true

    init(theme: Theme, start: URL?, hold: @escaping (Bool) -> Void, onChoose: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.theme = theme
        self.start = start
        self.hold = hold
        self.onChoose = onChoose
        self.onCancel = onCancel
        // nur, wenn der Ordner noch erreichbar ist (Laufwerk angeschlossen)
        var isDir: ObjCBool = false
        let ok = start.map { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue } ?? false
        _current = State(initialValue: ok ? start : nil)
    }

    var body: some View {
        let t = theme
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if current != nil {
                    Button { go(parent(of: current!)) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            .foregroundColor(t.muted).frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Back"))
                }
                SectionTitle(title: current.map(displayName) ?? String(localized: "Choose a folder"), theme: t)
            }
            Text(current?.path ?? String(localized: "Choose the folder that contains “Avid MediaFiles”."))
                .font(.mono(11))
                .foregroundColor(t.faint)
                .lineLimit(1)
                .truncationMode(.middle)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { row($0, t) }
                }
            }
            .frame(height: 260)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.line, lineWidth: 1))
            .overlay {
                if loading || items.isEmpty {
                    if let readError, !loading {
                        Text(readError).font(.mono(11)).foregroundColor(t.error)
                            .multilineTextAlignment(.center).padding(14).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(loading ? "Loading…" : "No folders here.").font(.mono(12)).foregroundColor(t.faint)
                    }
                }
            }

            if current != nil {
                if let name = newFolder {
                    newFolderForm(name, t)
                } else {
                    Button("New folder…") { newFolder = ""; withAvid = true }
                        .buttonStyle(FerryButtonStyle(theme: t))
                }
            }
            if current == nil {
                HStack(spacing: 8) {
                    TextField("", text: $server)
                        .textFieldStyle(.plain)
                        .font(.mono(12))
                        .foregroundColor(t.text)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.line, lineWidth: 1))
                        .onSubmit(connect)
                    Button(connecting ? "Connecting…" : "Connect", action: connect)
                        .buttonStyle(FerryButtonStyle(theme: t))
                        .disabled(connecting)
                }
                Text("Connect a NAS, e.g. smb://nas/Archive").font(.mono(11)).foregroundColor(t.faint)
            }
            if let error {
                Text(error).font(.mono(11)).foregroundColor(t.error).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(FerryButtonStyle(theme: t))
                    .keyboardShortcut(.cancelAction)
                if let current {
                    Button("Choose “\(displayName(current))”") { onChoose(current) }
                        .buttonStyle(FerryButtonStyle(theme: t, primary: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .task(id: current) { await load() }
    }

    private func row(_ item: Item, _ t: Theme) -> some View {
        Button { go(item.url) } label: {
            HStack(spacing: 10) {
                Image(systemName: current == nil ? "externaldrive" : "folder")
                    .font(.system(size: 12))
                    .foregroundColor(t.muted)
                    .frame(width: 16)
                Text(item.name).font(.mono(12)).foregroundColor(t.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if item.avid {
                    Text("AVID")
                        .font(.mono(9, semibold: true))
                        .tracking(0.5)
                        .foregroundColor(t.online)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(t.online, lineWidth: 1))
                        .help(Text("Contains “Avid MediaFiles”"))
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundColor(t.faint)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle(theme: t))
    }

    private func newFolderForm(_ name: String, _ t: Theme) -> some View {
        let binding = Binding(get: { newFolder ?? "" }, set: { newFolder = $0 })
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("", text: binding, prompt: Text("Folder name"))
                    .textFieldStyle(.plain)
                    .font(.mono(12))
                    .foregroundColor(t.text)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.line, lineWidth: 1))
                    .onSubmit { create(trimmed) }
                Button("Create") { create(trimmed) }
                    .buttonStyle(FerryButtonStyle(theme: t))
                    .disabled(trimmed.isEmpty)
                Button { newFolder = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(t.muted)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel"))
            }
            Checkbox(title: "With “Avid MediaFiles/MXF” inside", on: withAvid, theme: t) { withAvid.toggle() }
        }
    }

    /// Neuer Ordner im aktuellen Ordner; danach ist er ausgewählt. Vorhandenes wird nie überschrieben.
    private func create(_ name: String) {
        guard let dir = current, !name.isEmpty else { return }
        do {
            let url = try makeFolder(named: name, in: dir, withAvid: withAvid)
            newFolder = nil
            go(url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func go(_ url: URL?) {
        error = nil
        current = url
    }

    /// Wurzel eines Laufwerks → zurück zur Laufwerksliste
    private func parent(of url: URL) -> URL? {
        let up = url.deletingLastPathComponent().path
        return url.path == "/" || up == "/Volumes" ? nil : url.deletingLastPathComponent()
    }

    private func displayName(_ url: URL) -> String {
        url.path == "/" ? ((try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "/") : url.lastPathComponent
    }

    private func load() async {
        loading = true
        let dir = current
        let (found, problem) = await Task.detached { FolderBrowser.read(dir) }.value
        guard dir == current else { return }
        items = found
        readError = problem
        loading = false
    }

    /// Unterordner (ohne versteckte und Pakete) bzw. eingehängte Laufwerke ohne die eigenen Spiegel-Volumes.
    nonisolated static func list(_ dir: URL?) -> [Item] { read(dir).0 }

    /// Wie `list`, zusätzlich eine verständliche Meldung, wenn der Ordner nicht gelesen werden kann.
    nonisolated static func read(_ dir: URL?) -> ([Item], String?) {
        let fm = FileManager.default
        let urls: [URL]
        if let dir {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            } catch let e as NSError {
                let denied = e.code == NSFileReadNoPermissionError || (e.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EPERM)
                return ([], denied
                    ? String(localized: "Mountpoint is not allowed to open this folder. Allow access under System Settings → Privacy & Security → Files and Folders (or Full Disk Access).")
                    : String(localized: "This folder cannot be read: \(e.localizedDescription)"))
            }
            urls = entries
                .filter { u in
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    return v?.isDirectory == true && v?.isPackage != true
                }
        } else {
            urls = (fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
                .filter { !Mounter.isMounted($0.path) }
        }
        let items: [Item] = urls.map { (u: URL) -> Item in
            let name = u.path == "/" ? ((try? u.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "/") : u.lastPathComponent
            return Item(url: u, name: name, avid: fm.fileExists(atPath: u.appendingPathComponent("Avid MediaFiles").path))
        }
        .sorted { (a: Item, b: Item) in a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return (items, nil)
    }

    private func connect() {
        let address = server.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: address), url.scheme != nil, url.host != nil else {
            error = String(localized: "Enter an address like smb://nas/Archive.")
            return
        }
        connecting = true
        error = nil
        hold(true)
        Task.detached {
            let result = Result { try Mounter.mountShare(url) }
            await MainActor.run {
                hold(false)
                connecting = false
                switch result {
                case .success(let path): go(URL(fileURLWithPath: path))
                case .failure(let e): error = e.localizedDescription
                }
            }
        }
    }
}

struct HoverRowStyle: ButtonStyle {
    let theme: Theme
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(theme.text.opacity(configuration.isPressed ? 0.12 : hover ? 0.06 : 0))
            .onHover { hover = $0 }
    }
}

/// Legt einen neuen Ordner an (Fehler, falls es ihn schon gibt), optional mit `Avid MediaFiles/MXF`.
func makeFolder(named name: String, in dir: URL, withAvid: Bool) throws -> URL {
    guard !name.contains("/"), !name.hasPrefix(".") else {
        throw MountError(message: String(localized: "Folder names cannot contain “/” or start with a dot."))
    }
    let url = dir.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: url.path) {
        throw MountError(message: String(localized: "“\(name)” already exists here."))
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    if withAvid { try createAvidFolders(in: url) }
    return url
}
