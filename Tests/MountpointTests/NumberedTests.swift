import Foundation
import Testing
@testable import Mountpoint

struct NumberedLogicTests {
    @Test func ownFolderOnNetworkDrives() {
        #expect(isOwnFolder("Mac Studio.1", computer: "Mac Studio"))
        #expect(isOwnFolder("mac studio.1", computer: "Mac Studio"))
        #expect(!isOwnFolder("Mac Studio.2", computer: "Mac Studio"))   // nur der 1er
        #expect(!isOwnFolder("Mac Studio 2.1", computer: "Mac Studio"))   // anderer Rechner
        #expect(!isOwnFolder("Mac Studio.", computer: "Mac Studio"))
        #expect(!isOwnFolder("1", computer: "Mac Studio"))
        #expect(!isOwnFolder(".1", computer: ""))
    }

    @Test func systemVolumeIsWatchedInSharedFolder() {
        #expect(guardRoot(systemGuard) == "/Users/Shared/AvidMediaComposer")
        #expect(guardRoot("LucidLink") == "/Volumes/LucidLink")
        // LucidLink 3 hängt eine Ebene tiefer ein
        #expect(guardEntry("/Volumes/Filespace/Projekt") == "/Volumes/Filespace/Projekt")
        #expect(guardEntry("/Volumes/LucidLink") == "LucidLink")
        #expect(guardRoot(guardEntry("/Volumes/Filespace/Projekt")) == "/Volumes/Filespace/Projekt")
        #expect(guardName("/Volumes/Filespace/Projekt") == "Projekt")
        #expect(!guardName(systemGuard).isEmpty && guardName(systemGuard) != systemGuard)
    }

    @Test @MainActor func errorsCanBeClearedPerProject() {
        let s = Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("mp-err-\(UUID())"))
        s.addProject("Doku")
        let p = s.library.projects[0].id
        s.add(URL(fileURLWithPath: "/tmp/a"), to: p)
        s.add(URL(fileURLWithPath: "/tmp/b"), to: p)
        s.add(URL(fileURLWithPath: "/tmp/c"), to: nil)
        for w in s.library.workspaces { s.errors[w.id] = "nicht erreichbar" }
        s.clearErrors(in: p)
        #expect(s.errors.keys.map { $0 } == [s.library.workspaces[2].id])
        #expect(s.state(of: p) == .none)
    }

    @Test func oldWorkspaceEntriesWithWarningStillLoad() throws {
        let json = #"{"workspaces":[{"id":"7C9F8E2A-1111-4222-8333-444455556666","path":"/x/AI_Media","warnNumbered":true}]}"#
        let lib = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        #expect(lib.workspaces.map(\.name) == ["AI_Media"])
    }

    @Test @MainActor func systemVolumeWatchesOwnFolderByDefault() {
        let s = Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("mp-sys-\(UUID())"))
        s.addGuard(systemGuard)
        s.addGuard("LucidLink")
        #expect(s.library.watchesOwn(systemGuard))
        #expect(!s.library.watchesOwn("LucidLink"))
        s.setGuardOwn(systemGuard, false)                // ältere Einträge ohne Auswahl: trotzdem eigener Ordner
        #expect(s.library.watchesOwn(systemGuard))
        s.setGuardOwn("LucidLink", true)
        #expect(s.library.watchesOwn("LucidLink"))
    }
}

/// Echtes Volume, echte Ordner. Nur mit MOUNTPOINT_IT=1.
@MainActor
struct NumberedIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUNTPOINT_IT"] == "1"))
    func warnsOnlyAboutANewOneFolder() async throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("NumTest\(getpid())")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Avid MediaFiles/MXF/1"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: src) }
        let w = Workspace(path: src.path)
        try Mounter.mount(w, helper: MountTests.helper)
        defer { try? Mounter.unmount(w) }

        let watch = FolderWatch(key: "net:" + w.volumePath, name: w.name, mxf: w.volumePath + "/Avid MediaFiles/MXF", kind: .network, matches: { $0 == "1" })
        let guardian = VolumeGuard(names: { [] }, numbered: { [watch] })
        var alerts: [[String]] = []
        guardian.presentNumbered = { _, folders in alerts.append(folders) }
        guardian.refresh()
        for _ in 0..<50 where !guardian.idle { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(alerts.isEmpty, "\"1\" existed before – not new")

        let mxf = w.volumePath + "/Avid MediaFiles/MXF/"
        try FileManager.default.createDirectory(atPath: mxf + "Mac Studio.1", withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: mxf + "2", withIntermediateDirectories: false)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(alerts.isEmpty, "only \"1\" counts")

        // gelöscht und neu angelegt → Alarm
        try FileManager.default.removeItem(atPath: mxf + "1")
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 100_000_000) }
        try FileManager.default.createDirectory(atPath: mxf + "1", withIntermediateDirectories: false)
        for _ in 0..<30 where alerts.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(alerts == [["1"]])
        guardian.acknowledgeNumbered(watch, ["1"])
        try await Task.sleep(nanoseconds: 1_000_000_000)   // Volume registriert sich, bevor es ausgeworfen wird
    }
}
