import AppKit
import Foundation

/// Version from a release tag like "v1.0.0-beta.7". Final releases rank above their betas.
struct AppVersion: Comparable, Equatable {
    let numbers: [Int]
    let beta: Int?   // nil = final release

    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: "-", maxSplits: 1)
        let nums = parts[0].split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, !nums.contains(nil) else { return nil }
        numbers = nums.map { $0! }
        if parts.count == 2 {
            guard let b = Int(parts[1].lowercased().replacingOccurrences(of: "beta.", with: "")) else { return nil }
            beta = b
        } else {
            beta = nil
        }
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }   // 1.0 == 1.0.0

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.numbers.count, b.numbers.count)
        let x = a.numbers + Array(repeating: 0, count: n - a.numbers.count)
        let y = b.numbers + Array(repeating: 0, count: n - b.numbers.count)
        if x != y { return x.lexicographicallyPrecedes(y) }
        switch (a.beta, b.beta) {
        case let (p?, q?): return p < q
        case (_?, nil): return true
        default: return false
        }
    }
}

struct Release {
    let tag: String
    let page: URL
    let zip: URL
}

/// Newest non-draft release with a Mountpoint zip, from GitHub's releases JSON.
func newestRelease(fromJSON data: Data) -> Release? {
    struct Asset: Decodable { let name: String; let browser_download_url: URL }
    struct R: Decodable { let tag_name: String; let html_url: URL; let draft: Bool; let assets: [Asset] }
    guard let list = try? JSONDecoder().decode([R].self, from: data) else { return nil }
    return list
        .filter { !$0.draft && AppVersion($0.tag_name) != nil }
        .compactMap { r -> (AppVersion, Release)? in
            guard let zip = r.assets.first(where: { $0.name.hasPrefix("Mountpoint-") && $0.name.hasSuffix(".zip") }) else { return nil }
            return (AppVersion(r.tag_name)!, Release(tag: r.tag_name, page: r.html_url, zip: zip.browser_download_url))
        }
        .max { $0.0 < $1.0 }?.1
}

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate, installing
        case failed(String)
    }

    @Published var available: Release?
    @Published var state = State.idle

    static let current = Bundle.main.object(forInfoDictionaryKey: "MountpointRelease") as? String ?? "dev"
    private static let api = URL(string: "https://api.github.com/repos/moritz-poth/mountpoint/releases?per_page=20")!
    private var timer: Timer?

    /// Checks shortly after launch and then every 6 hours, quietly.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(manual: false) }
        }
    }

    func check(manual: Bool) {
        guard state != .checking, state != .installing else { return }
        if manual { state = .checking }
        var request = URLRequest(url: Self.api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let release = ok ? data.flatMap(newestRelease(fromJSON:)) : nil
            Task { @MainActor in
                guard self.state != .installing else { return }
                if let release, let new = AppVersion(release.tag), let mine = AppVersion(Self.current), mine < new {
                    self.available = release
                    if manual { self.state = .idle }
                } else if release != nil {
                    self.available = nil
                    if manual { self.state = .upToDate }
                } else if manual {
                    self.state = .failed(String(localized: "Could not check for updates. Check the internet connection and try again."))
                }
            }
        }.resume()
    }

    /// Downloads the zip, verifies the app inside, swaps it in place of the running app and restarts.
    /// The old version goes to the Trash. Mounted workspaces are ejected and mounted again by the new version.
    func install() {
        guard let release = available, state != .installing else { return }
        state = .installing
        URLSession.shared.downloadTask(with: release.zip) { file, response, error in
            let result: Result<URL, Error>
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                result = Result { try Self.unpack(file, expecting: release.tag) }
            } else {
                result = .failure(UpdateError(String(localized: "The update could not be downloaded. Check the internet connection and try again.")))
            }
            Task { @MainActor in
                switch result {
                case .success(let app):
                    do { try self.swapAndRestart(with: app) } catch { self.state = .failed(error.localizedDescription) }
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        }.resume()
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Unzips into a temporary folder and checks that it really is the expected, intact Mountpoint version.
    nonisolated static func unpack(_ zip: URL, expecting tag: String, bundleID: String? = Bundle.main.bundleIdentifier) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mountpoint-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let damaged = UpdateError(String(localized: "The downloaded update is damaged. Please try again later or download it from GitHub."))
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) else { throw damaged }
        let app = dir.appendingPathComponent("Mountpoint.app")
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == bundleID,
              let release = info["MountpointRelease"] as? String,
              AppVersion(release) == AppVersion(tag),
              run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        else { throw damaged }
        return app
    }

    private func swapAndRestart(with app: URL) throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        var trashed: NSURL?
        do {
            try fm.trashItem(at: current, resultingItemURL: &trashed)
        } catch {
            throw UpdateError(String(localized: "Mountpoint could not replace itself. Move it to the Applications folder, or download the update from GitHub.") + "\n\n" + String(localized: "Details: \(error.localizedDescription)"))
        }
        do {
            try fm.moveItem(at: app, to: current)
        } catch {
            if let trashed = trashed as URL? { try? fm.moveItem(at: trashed, to: current) }
            throw UpdateError(String(localized: "Mountpoint could not replace itself. Move it to the Applications folder, or download the update from GitHub.") + "\n\n" + String(localized: "Details: \(error.localizedDescription)"))
        }
        // start the new version once this one has quit
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 $1 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                       current.path, String(ProcessInfo.processInfo.processIdentifier)]
        do { try p.run() } catch {
            state = .failed(String(localized: "The update is installed. Quit Mountpoint and open it again to finish."))
            return
        }
        Store.shared.rememberMountedForUpdate()
        NSApp.terminate(nil)   // ejects the volumes; the new version mounts them again
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
