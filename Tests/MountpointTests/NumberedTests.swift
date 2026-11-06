import Foundation
import Testing
@testable import Mountpoint

struct NumberedLogicTests {
    @Test func onlyDigitsCount() {
        #expect(isNumberedFolder("1"))
        #expect(isNumberedFolder("12"))
        #expect(!isNumberedFolder("Mac Studio.1"))
        #expect(!isNumberedFolder("1a"))
        #expect(!isNumberedFolder(""))
        #expect(!isNumberedFolder("١"))   // keine nicht-lateinischen Ziffern
    }

    @Test func ownFolderOnNetworkDrives() {
        #expect(isOwnFolder("Mac Studio.1", computer: "Mac Studio"))
        #expect(isOwnFolder("mac studio.12", computer: "Mac Studio"))
        #expect(!isOwnFolder("Mac Studio 2.1", computer: "Mac Studio"))   // anderer Rechner
        #expect(!isOwnFolder("Mac Studio.", computer: "Mac Studio"))
        #expect(!isOwnFolder("1", computer: "Mac Studio"))
        #expect(!isOwnFolder(".1", computer: ""))
    }

    @Test func systemVolumeIsWatchedInSharedFolder() {
        #expect(guardRoot(systemGuard) == "/Users/Shared/AvidMediaComposer")
        #expect(guardRoot("LucidLink") == "/Volumes/LucidLink")
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

    @Test func oldWorkspaceEntriesStillLoad() throws {
        let json = #"{"workspaces":[{"id":"7C9F8E2A-1111-4222-8333-444455556666","path":"/x/AI_Media"}]}"#
        let lib = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        #expect(lib.workspaces[0].warnNumbered == nil)
    }

    @Test @MainActor func projectCheckmarkFollowsWorkspaces() {
        let s = Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("mp-num-\(UUID())"))
        s.addProject("Doku")
        let p = s.library.projects[0].id
        s.add(URL(fileURLWithPath: "/tmp/a"), to: p)
        s.add(URL(fileURLWithPath: "/tmp/b"), to: p)
        #expect(!s.projectWarns(p))
        s.toggleProjectWarn(p)                       // Projekt an → alle an
        #expect(s.library.workspaces.allSatisfy { $0.warnNumbered == true })
        s.toggleWarn(s.library.workspaces[0])        // einen aus → Projekt aus, der andere bleibt an
        #expect(!s.projectWarns(p))
        #expect(s.library.workspaces[1].warnNumbered == true)
        s.toggleWarn(s.library.workspaces[0])        // wieder an → Projekt an
        #expect(s.projectWarns(p))
        s.add(URL(fileURLWithPath: "/tmp/c"), to: p) // neuer Workspace erbt
        #expect(s.library.workspaces[2].warnNumbered == true)
        s.toggleProjectWarn(p)                       // Projekt aus → alle aus
        #expect(s.library.workspaces.allSatisfy { $0.warnNumbered == false })
    }
}

/// Echtes Volume, echte Ordner. Nur mit MOUNTPOINT_IT=1.
@MainActor
struct NumberedIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUNTPOINT_IT"] == "1"))
    func warnsOnlyAboutNewNumberedFolders() async throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("NumTest\(getpid())")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Avid MediaFiles/MXF/1"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: src) }
        var w = Workspace(path: src.path)
        w.warnNumbered = true
        try Mounter.mount(w, helper: MountTests.helper)
        defer { try? Mounter.unmount(w) }

        let watch = FolderWatch(workspace: w)
        let guardian = VolumeGuard(names: { [] }, numbered: { [watch] })
        var alerts: [[String]] = []
        guardian.presentNumbered = { _, folders in alerts.append(folders) }
        guardian.refresh()
        #expect(alerts.isEmpty, "\"1\" existed before – not new")

        let mxf = w.volumePath + "/Avid MediaFiles/MXF/"
        try FileManager.default.createDirectory(atPath: mxf + "Mac Studio.1", withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: mxf + "2", withIntermediateDirectories: false)
        for _ in 0..<30 where alerts.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(alerts == [["2"]])

        guardian.acknowledgeNumbered(watch, ["2"])
        try FileManager.default.createDirectory(atPath: mxf + "3", withIntermediateDirectories: false)
        for _ in 0..<30 where alerts.count < 2 { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(alerts.last == ["3"])

        // gelöscht und neu angelegt → wieder ein Alarm
        guardian.acknowledgeNumbered(watch, ["3"])
        try FileManager.default.removeItem(atPath: mxf + "1")
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 100_000_000) }
        try FileManager.default.createDirectory(atPath: mxf + "1", withIntermediateDirectories: false)
        for _ in 0..<30 where alerts.count < 3 { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(alerts.last == ["1"])
        try await Task.sleep(nanoseconds: 1_000_000_000)   // Volume registriert sich, bevor es ausgeworfen wird
    }
}
