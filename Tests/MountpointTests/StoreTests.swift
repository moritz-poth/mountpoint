import Foundation
import Testing
@testable import Mountpoint

@MainActor
struct StoreTests {
    func makeStore() -> Store {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-store-\(UUID())")
        return Store(directory: dir)
    }

    func projectWithTwo(_ s: Store) -> Project {
        s.addProject("Doku")
        let p = s.library.projects[0]
        s.add(URL(fileURLWithPath: "/tmp/a"), to: p.id)
        s.add(URL(fileURLWithPath: "/tmp/b"), to: p.id)
        s.add(URL(fileURLWithPath: "/tmp/c"), to: nil)
        return p
    }

    @Test func deleteProjectRemovesWorkspaces() {
        let s = makeStore()
        let p = projectWithTwo(s)
        s.delete(p, removeWorkspaces: true)
        #expect(s.library.projects.isEmpty)
        #expect(s.library.workspaces.map(\.name) == ["c"])
    }

    @Test func deleteProjectKeepsWorkspaces() {
        let s = makeStore()
        let p = projectWithTwo(s)
        s.delete(p, removeWorkspaces: false)
        #expect(s.library.workspaces.count == 3)
        #expect(s.workspaces(in: nil).count == 3)
    }

    @Test func stateOfProject() {
        let s = makeStore()
        let p = projectWithTwo(s)
        #expect(s.state(of: p.id) == .none)
        s.errors[s.library.workspaces[0].id] = "Fehler"
        #expect(s.state(of: p.id) == .partial)
        s.addProject("Leer")
        #expect(s.state(of: s.library.projects[1].id) == .none)
    }

    @Test func persists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-store-\(UUID())")
        let s = Store(directory: dir)
        _ = projectWithTwo(s)
        #expect(Store(directory: dir).library.workspaces.count == 3)
    }
}
