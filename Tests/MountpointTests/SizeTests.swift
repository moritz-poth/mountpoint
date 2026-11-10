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
        #expect(fileCount(dir.path) == 37)                  // wie MediaFiles Check: ohne versteckte Dateien und Ordner
        #expect(fileCount(dir.path + "/fehlt") == nil)
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
        let guardian = VolumeGuard(names: { [] }, numbered: { [] }, sizeRoots: { [SizeRoot(name: "Test", root: root.path)] }, persist: false)
        guardian.sizeLimit = 10
        guardian.earlyLimit = 10   // nur die Warnung über der Grenze
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

    /// Vorwarnung über earlyLimit; ihr „OK“ hält still bis sizeLimit, dann warnt es noch einmal.
    @Test func warnsEarlyThenAgainAtLimit() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("mp-early-\(UUID())")
        let folder = root.appendingPathComponent("Avid MediaFiles/MXF/1")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func files(_ n: Int) throws {
            for f in try fm.contentsOfDirectory(atPath: folder.path) { try fm.removeItem(atPath: folder.path + "/" + f) }
            for i in 0..<n { fm.createFile(atPath: folder.path + "/f\(i).mxf", contents: nil) }
        }
        let guardian = VolumeGuard(names: { [] }, numbered: { [] }, sizeRoots: { [SizeRoot(name: "Test", root: root.path)] }, persist: false)
        guardian.earlyLimit = 8
        guardian.sizeLimit = 10
        var alerts: [Int] = []
        guardian.presentSize = { _, _, n in alerts.append(n) }
        func check() async throws {
            guardian.checkSizes()
            for _ in 0..<50 where !guardian.sizeIdle { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        try files(8)
        try await check()
        #expect(alerts.isEmpty)
        try files(9)
        try await check()
        #expect(alerts == [9], "early warning")
        guardian.acknowledgeSize(folder.path, early: true)
        try files(10)
        try await check()
        #expect(alerts == [9], "early warning acknowledged, not over the limit yet")
        try files(11)
        try await check()
        #expect(alerts == [9, 11], "over the limit: warns again")
        guardian.acknowledgeSize(folder.path)
        try files(12)
        try await check()
        #expect(alerts == [9, 11])
    }

    /// Vorwarnung standardmäßig ab 90 %, aber genau an der Grenze nie (so voll füllt MediaFiles Check beim Rebalancing).
    @Test func exactLimitNeverWarns() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("mp-exact-\(UUID())")
        let folder = root.appendingPathComponent("Avid MediaFiles/MXF/1")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func files(_ n: Int) throws {
            for f in try fm.contentsOfDirectory(atPath: folder.path) { try fm.removeItem(atPath: folder.path + "/" + f) }
            for i in 0..<n { fm.createFile(atPath: folder.path + "/f\(i).mxf", contents: nil) }
        }
        let guardian = VolumeGuard(names: { [] }, numbered: { [] }, sizeRoots: { [SizeRoot(name: "Test", root: root.path)] }, persist: false)
        guardian.sizeLimit = 20   // Vorwarnung über 18
        var alerts: [Int] = []
        guardian.presentSize = { _, _, n in alerts.append(n) }
        func check() async throws {
            guardian.checkSizes()
            for _ in 0..<50 where !guardian.sizeIdle { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        try files(18)
        try await check()
        try files(20)
        try await check()
        fm.createFile(atPath: folder.path + "/.DS_Store", contents: nil)
        try fm.createDirectory(at: folder.appendingPathComponent("Creating"), withIntermediateDirectories: false)
        try await check()
        #expect(alerts.isEmpty, "18 is not over 90 %, exactly 20 is not over the limit (.DS_Store and Creating do not count)")
        try files(19)
        fm.createFile(atPath: folder.path + "/.DS_Store", contents: nil)
        try await check()
        #expect(alerts.isEmpty, "exactly full (rebalanced) counts as acknowledged: one file less does not warn")
        try files(17)
        try await check()
        try files(19)
        try await check()
        #expect(alerts == [19], "below 90 % resets: early warning between 90 % and the limit")
        guardian.acknowledgeSize(folder.path, early: true)
        try files(20)
        try await check()
        try files(19)
        try await check()
        #expect(alerts == [19], "an acknowledged early warning survives exactly the limit")
        try files(21)
        try await check()
        #expect(alerts == [19, 21], "one file over the limit")
    }

    /// Während einer Zählung ausgeschaltet: das Ergebnis öffnet keinen Alarm mehr.
    @Test func switchedOffDuringCount() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("mp-off-\(UUID())")
        let folder = root.appendingPathComponent("Avid MediaFiles/MXF/1")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 0..<25 { fm.createFile(atPath: folder.path + "/f\(i).mxf", contents: nil) }
        var on = true
        let guardian = VolumeGuard(names: { [] }, numbered: { [] }, sizeRoots: { on ? [SizeRoot(name: "Test", root: root.path)] : [] }, persist: false)
        guardian.sizeLimit = 20
        var alerts: [Int] = []
        guardian.presentSize = { _, _, n in alerts.append(n) }
        guardian.checkSizes()
        on = false   // die Zählung läuft schon (ihr Ergebnis kommt erst nach dem nächsten await auf dem Haupt-Thread an)
        for _ in 0..<50 where !guardian.sizeIdle { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(alerts.isEmpty)
    }

    /// Bestätigungen: Sturz vom Alarm direkt in den Vorwarnbereich warnt früh, ein fehlender Ordner vergisst die
    /// Bestätigung, gemessen wird an der aktuellen Grenze.
    @Test func acknowledgementCases() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("mp-ack-\(UUID())")
        let folder = root.appendingPathComponent("Avid MediaFiles/MXF/1")
        let away = root.appendingPathComponent("weg")   // außerhalb von MXF
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func files(_ n: Int) throws {
            for f in try fm.contentsOfDirectory(atPath: folder.path) { try fm.removeItem(atPath: folder.path + "/" + f) }
            for i in 0..<n { fm.createFile(atPath: folder.path + "/f\(i).mxf", contents: nil) }
        }
        let guardian = VolumeGuard(names: { [] }, numbered: { [] }, sizeRoots: { [SizeRoot(name: "Test", root: root.path)] }, persist: false)
        guardian.sizeLimit = 20   // Vorwarnung über 18
        var alerts: [Int] = []
        guardian.presentSize = { _, _, n in alerts.append(n) }
        func check() async throws {
            guardian.checkSizes()
            for _ in 0..<50 where !guardian.sizeIdle { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        try files(25)
        try await check()
        #expect(alerts == [25])
        guardian.acknowledgeSize(folder.path)
        try files(19)                                     // vom Alarm direkt in den Vorwarnbereich
        try await check()
        #expect(alerts == [25, 19], "a new, lower threshold was crossed")
        guardian.acknowledgeSize(folder.path, early: true)
        try fm.moveItem(at: folder, to: away)             // einmal nicht da (Laufwerk weg)
        try await check()
        try fm.moveItem(at: away, to: folder)
        try await check()
        #expect(alerts == [25, 19, 19], "a missing folder forgets its acknowledgement")
        guardian.acknowledgeSize(folder.path, early: true)
        guardian.sizeLimit = 40                           // jetzt unter 90 % von 40: Bestätigung verfällt
        try await check()
        guardian.sizeLimit = 20
        try await check()
        #expect(alerts == [25, 19, 19, 19], "acknowledgements are judged against the current limit")
    }
}
