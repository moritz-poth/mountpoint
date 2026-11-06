import Foundation
import Testing
@testable import Mountpoint

struct GuardLogicTests {
    @Test func oldLibraryWithoutGuardedStillLoads() throws {
        let json = #"{"projects":[],"workspaces":[{"id":"7C9F8E2A-1111-4222-8333-444455556666","path":"/x/AI_Media"}]}"#
        let lib = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        #expect(lib.workspaces.map(\.name) == ["AI_Media"])
        #expect(lib.guarded.isEmpty)
    }

    @Test func snoozeEnds() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 22, minute: 30))!
        #expect(snoozeEnd(.minutes(15), from: now, calendar: cal) == now.addingTimeInterval(900))
        // Nacht der Zeitumstellung (25.10.): trotzdem genau Mitternacht
        let end = snoozeEnd(.restOfDay, from: now, calendar: cal)
        #expect(cal.dateComponents([.day, .hour, .minute], from: end) == DateComponents(day: 25, hour: 0, minute: 0))
        #expect(Snooze.all.count == 9)
    }
}

/// Echtes Volume (Spiegel-Helfer), echter kqueue-Alarm. Nur mit MOUNTPOINT_IT=1.
@MainActor
struct GuardIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUNTPOINT_IT"] == "1"))
    func alertsWhenAvidFolderAppears() async throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("GuardTest\(getpid())")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: src) }
        let w = Workspace(path: src.path)
        try Mounter.mount(w, helper: MountTests.helper)
        defer { try? Mounter.unmount(w) }

        let guardian = VolumeGuard(names: { [w.name] })
        var alerted: [String] = []
        guardian.present = { alerted.append($0) }
        guardian.refresh()
        for _ in 0..<50 where !guardian.idle { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(alerted.isEmpty)

        try FileManager.default.createDirectory(atPath: w.volumePath + "/Avid MediaFiles", withIntermediateDirectories: false)
        for _ in 0..<30 where alerted.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(alerted == [w.name])
        guardian.refresh()   // Ordner liegt noch da, Volume bleibt beobachtet

        // wie ein Neustart der App: neuer Wächter, Ordner liegt schon da → sofort Alarm
        let restarted = VolumeGuard(names: { [w.name] })
        var again: [String] = []
        restarted.present = { again.append($0) }
        restarted.refresh()
        for _ in 0..<50 where !restarted.idle { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(again == [w.name])
    }
}
