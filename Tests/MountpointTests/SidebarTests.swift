import Foundation
import Testing
@testable import Mountpoint

struct SidebarTests {
    /// Nur eigene Einträge (ohne Name/DateLastSeen) ausgeworfener Volumes mit unseren Namen werden gelöscht.
    @Test func staleOnlyOwnEjectedEntries() throws {
        // irgendein Volume, das es gibt (Lesezeichen brauchen ein existierendes Ziel); „ausgeworfen“ simuliert `exists`
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: "/Volumes").first { !$0.hasPrefix(".") })
        let bookmark = try URL(fileURLWithPath: "/Volumes/" + name).bookmarkData()
        let item: [String: Any] = ["Bookmark": bookmark, "uuid": "x", "visibility": 1]
        let gone: (String) -> Bool = { _ in false }
        #expect(Sidebar.isStale(item, names: [name], exists: gone))
        #expect(!Sidebar.isStale(item, names: [name], exists: { _ in true }))          // eingehängt
        #expect(!Sidebar.isStale(item, names: ["Other"], exists: gone))                  // fremder Name
        #expect(!Sidebar.isStale(item.merging(["Name": name]) { $1 }, names: [name], exists: gone))   // Eintrag des Finders
        #expect(!Sidebar.isStale(item.merging(["CustomItemProperties": ["com.apple.LSSharedFileList.DateLastSeen": Date()]]) { $1 },
                                 names: [name], exists: gone))
        #expect(!Sidebar.isStale(["uuid": "x"], names: [name], exists: gone))           // ohne Lesezeichen
    }
}
