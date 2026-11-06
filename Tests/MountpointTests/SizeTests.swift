import Foundation
import Testing
@testable import Mountpoint

@MainActor
struct SizeTests {
    let fm = FileManager.default

    @Test func countsEntriesBothWays() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("mp-count-\(UUID())")
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for i in 0..<37 { fm.createFile(atPath: dir.path + "/f\(i).mxf", contents: nil) }
        fm.createFile(atPath: dir.path + "/.hidden", contents: nil)
        #expect(entryCount(dir.path) == 39)                 // ein Aufruf (APFS)
        #expect(entryCount(dir.path, quick: false) == 39)   // Namen zählen (SMB, macFUSE)
        #expect(entryCount(dir.path + "/fehlt") == nil)
    }

    /// Warnung über der Grenze, „OK“ hält still, unter die Grenze und wieder darüber warnt erneut.
    @Test func warnsOncePerCrossing() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("mp-size-\(UUID())")
        let folder = root.appendingPathComponent("Avid MediaFiles/MXF/1")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Avid MediaFiles/MXF/Mac Studio.1"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func files(_ n: Int) throws {
            for f in try fm.contentsOfDirectory(atPath: folder.path) { try fm.removeItem(atPath: folder.path + "/" + f) }
            for i in 0..<n { fm.createFile(atPath: folder.path + "/f\(i).mxf", contents: nil) }
        }
        let guardian = VolumeGuard(names: { [] }, numbered: { [] }, sizeRoots: { [SizeRoot(name: "Test", root: root.path)] })
        guardian.sizeLimit = 10
        var alerts: [(String, String, Int)] = []
        guardian.presentSize = { alerts.append(($0, $1, $2)) }
        func check() async throws {
            guardian.checkSizes()
            for _ in 0..<50 where !guardian.sizeIdle { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        try files(10)
        try await check()
        #expect(alerts.isEmpty, "10 is not more than 10")
        try files(11)
        try await check()
        #expect(alerts.count == 1 && alerts.first?.2 == 11 && alerts.first?.0 == "Test")
        guardian.acknowledgeSize(folder.path)
        try files(12)
        try await check()
        #expect(alerts.count == 1, "acknowledged – no new alert while it stays big")
        try files(3)
        try await check()
        try files(15)
        try await check()
        #expect(alerts.count == 2 && alerts.last?.2 == 15, "dropped below and crossed again")
        guardian.acknowledgeSize(folder.path)
    }
}
