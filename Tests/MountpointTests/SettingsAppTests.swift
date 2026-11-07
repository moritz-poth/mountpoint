import Foundation
import Testing
@testable import Mountpoint

/// Mountpoint und die Einstellungs-App arbeiten mit derselben library.json und denselben Einstellungen.
@MainActor
struct SettingsAppTests {
    func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mp-settingsapp-\(UUID())") }

    @Test func bothSidesSeeEachOthersLibraryChanges() {
        let d = dir()
        let app = Store(directory: d)
        let settings = Store(directory: d, passive: true)
        app.add(URL(fileURLWithPath: "/Volumes/NAS/Film/FF_Dailies"), to: nil)
        settings.reloadLibrary()
        #expect(settings.library.workspaces.count == 1)
        // die Einstellungs-App ändert geschützte Volumes – die Workspaces von Mountpoint bleiben erhalten
        settings.addGuard("LucidLink")
        app.reloadLibrary()
        #expect(app.library.guarded.contains("LucidLink"))
        #expect(app.library.workspaces.count == 1, "a workspace got lost through the settings app")
        // und umgekehrt: ein neuer Workspace in Mountpoint überschreibt die Änderung der Einstellungs-App nicht
        app.add(URL(fileURLWithPath: "/Volumes/NAS/Film/FF_Render"), to: nil)
        settings.reloadLibrary()
        #expect(settings.library.guarded.contains("LucidLink") && settings.library.workspaces.count == 2)
    }

    /// Jede Einstellung, die das andere Programm ändert, kommt an (im echten Betrieb über die Nachricht "settings").
    @Test func settingsChangedElsewhereAreReloaded() {
        let d = defaults
        let keys = ["network", "watchNetwork", "watchSize", "betas", "sidebar", "dark", "language", "AppleLanguages"]
        let before = keys.map { d.object(forKey: $0) }
        let bundleBefore = languageBundle
        defer {
            for (k, v) in zip(keys, before) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            languageBundle = bundleBefore
        }
        let app = Store(directory: dir())
        let want = (!app.network, !app.watchNetwork, !app.watchSize, !app.betas, !app.sidebar, !app.dark)
        d.set(want.0, forKey: "network"); d.set(want.1, forKey: "watchNetwork"); d.set(want.2, forKey: "watchSize")
        d.set(want.3, forKey: "betas"); d.set(want.4, forKey: "sidebar"); d.set(want.5, forKey: "dark")
        let lang = app.language == "de" ? "fr" : "de"
        d.set(lang, forKey: "language")
        app.reloadSettings()
        #expect(app.network == want.0 && app.watchNetwork == want.1 && app.watchSize == want.2)
        #expect(app.betas == want.3 && app.sidebar == want.4 && app.dark == want.5)
        #expect(app.language == lang)
    }

    /// Ohne Leserecht ist die Datei nicht „leer“: die Einstellungs-App schreibt nichts (sonst wäre die Liste weg).
    @Test func libraryWithoutReadPermissionIsNeverOverwritten() throws {
        let d = dir()
        let app = Store(directory: d)
        app.add(URL(fileURLWithPath: "/Volumes/NAS/Film/FF_Dailies"), to: nil)
        let file = d.appendingPathComponent("library.json")
        let original = try Data(contentsOf: file)
        chmod(file.path, 0)
        defer { chmod(file.path, 0o644) }
        let settings = Store(directory: d, passive: true)
        #expect(settings.readOnly && settings.notice != nil)
        settings.addGuard("LucidLink")
        chmod(file.path, 0o644)
        #expect(try Data(contentsOf: file) == original, "the settings app overwrote a list it could not read")
    }

    /// Wird die Datei nach dem Laden kaputt: die Einstellungs-App lehnt ab (nichts Ungespeichertes im Fenster), Mountpoint
    /// legt sie beiseite und schreibt seine vollständige Liste; danach ist die Einstellungs-App wieder beschreibbar.
    @Test func libraryCorruptedAfterLoadIsRepairedByMountpoint() throws {
        let d = dir()
        let app = Store(directory: d)
        app.add(URL(fileURLWithPath: "/Volumes/NAS/Film/FF_Dailies"), to: nil)
        app.addGuard("Avid")
        let settings = Store(directory: d, passive: true)
        let file = d.appendingPathComponent("library.json")
        try Data("not json".utf8).write(to: file)
        settings.addGuard("LucidLink")
        #expect(try Data(contentsOf: file) == Data("not json".utf8), "the settings app wrote over the unreadable file")
        #expect(settings.readOnly && settings.notice == Store.readOnlyText && settings.library.guarded == ["Avid"])
        settings.addGuard("LucidLink")   // weiter abgelehnt, ohne Änderung im Speicher
        #expect(settings.library.guarded == ["Avid"])
        app.add(URL(fileURLWithPath: "/Volumes/NAS/Film/FF_Render"), to: nil)
        let aside = try FileManager.default.contentsOfDirectory(atPath: d.path).filter { $0.hasPrefix("library-unreadable") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: d.appendingPathComponent(aside[0])) == Data("not json".utf8), "the unreadable original is gone")
        let repaired = Store(directory: d).library
        #expect(repaired.workspaces.count == 2 && repaired.guarded == ["Avid"], "Mountpoint did not save the list it had open")
        settings.reloadLibrary()
        #expect(!settings.readOnly && settings.notice == nil)
        settings.addGuard("LucidLink")
        #expect(Store(directory: d).library.guarded == ["Avid", "LucidLink"])
    }

    /// Schreibgeschützt ab dem Start, später wieder lesbar: die geschützten Volumes auf der Platte bleiben erhalten.
    @Test func readOnlyFromLaunchNeverReplacesTheGuardList() throws {
        let d = dir()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let file = d.appendingPathComponent("library.json")
        try Data("not json".utf8).write(to: file)
        let settings = Store(directory: d, passive: true)
        settings.addGuard("X")
        #expect(settings.library.guarded.isEmpty)
        try JSONEncoder().encode(Library(guarded: ["A", "B"])).write(to: file)
        settings.reloadLibrary()
        settings.addGuard("X")
        #expect(Store(directory: d).library.guarded == ["A", "B", "X"], "recovery replaced the protected volumes")
    }

    /// Kann Mountpoint die kaputte Datei nicht beiseitelegen, schreibt es sie auch nicht – beim Start nicht und später nicht.
    @Test func unreadableFileThatCannotBeMovedIsNeverWritten() throws {
        let d = dir()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let file = d.appendingPathComponent("library.json")
        try Data("not json".utf8).write(to: file)
        chmod(d.path, 0o555)
        defer { chmod(d.path, 0o755) }
        let app = Store(directory: d)
        #expect(app.notice == Store.cannotSetAside)
        app.addProject("Doku")
        #expect(try Data(contentsOf: file) == Data("not json".utf8))
        // später repariert (Rechte, gute Kopie): Mountpoint übernimmt die Liste, statt sie mit seiner leeren zu überschreiben
        chmod(d.path, 0o755)
        let good = Library(projects: [Project(name: "Film")], workspaces: [Workspace(path: "/Volumes/NAS/Film/FF_Dailies")])
        try JSONEncoder().encode(good).write(to: file)
        app.reloadLibrary()
        #expect(app.library.workspaces.count == 1 && Store(directory: d).library.workspaces.count == 1, "the repaired list was overwritten")
        app.addProject("Doku")
        let disk = Store(directory: d).library
        #expect(disk.workspaces.count == 1 && disk.projects.count == 2)
    }

    /// Gelöscht, während Mountpoint läuft; eine neu gestartete Einstellungs-App schreibt eine Datei ohne Workspaces –
    /// Mountpoint behält trotzdem seine Liste und schreibt sie wieder.
    @Test func libraryDeletedWhileMountpointRuns() throws {
        let d = dir()
        let app = Store(directory: d)
        app.add(URL(fileURLWithPath: "/Volumes/NAS/Film/FF_Dailies"), to: nil)
        let file = d.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: file)
        let settings = Store(directory: d, passive: true)
        settings.addGuard("LucidLink")
        #expect(!settings.readOnly && Store(directory: d).library.guarded == ["LucidLink"])
        app.reloadLibrary()
        #expect(app.library.workspaces.count == 1, "Mountpoint took the empty workspace list of the settings app")
        // sofort wieder auf der Platte – ohne weitere Änderung (Beenden direkt danach verliert nichts)
        let disk = Store(directory: d).library
        #expect(disk.workspaces.count == 1 && disk.guarded == ["LucidLink"], "Mountpoint did not write its workspaces back")
        // gelöscht und nur neu geladen: Mountpoint legt die Datei sofort wieder an
        try FileManager.default.removeItem(at: file)
        app.reloadLibrary()
        #expect(Store(directory: d).library.workspaces.count == 1)
    }

    /// Der Fall aus dem Review: beide ändern, ohne die Nachricht des anderen schon verarbeitet zu haben.
    @Test func editsWithoutReloadInBetweenAreNeverLost() {
        let d = dir()
        let app = Store(directory: d)
        let settings = Store(directory: d, passive: true)
        app.add(URL(fileURLWithPath: "/Volumes/NAS/Film/FF_Dailies"), to: nil)
        settings.addGuard("LucidLink")              // die Einstellungs-App kennt den neuen Workspace noch nicht
        app.add(URL(fileURLWithPath: "/Volumes/NAS/Film/FF_Render"), to: nil)   // Mountpoint kennt das Volume noch nicht
        settings.setGuardOwn("LucidLink", true)
        let fresh = Store(directory: d)
        #expect(fresh.library.workspaces.count == 2, "a workspace was overwritten by the settings app")
        #expect(fresh.library.guarded == ["LucidLink"] && fresh.library.guardOwn == ["LucidLink"], "a protected volume was overwritten by Mountpoint")
        // nach dem Speichern kennen beide den vollen Stand
        #expect(app.library.guarded == ["LucidLink"] && settings.library.workspaces.count == 2)
    }

    @Test func unreadableLibraryIsNeverSetAsideOrOverwrittenByTheSettingsApp() throws {
        let d = dir()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let file = d.appendingPathComponent("library.json")
        try Data("not json".utf8).write(to: file)
        let settings = Store(directory: d, passive: true)
        #expect(settings.readOnly && settings.notice != nil)
        settings.addGuard("LucidLink")
        #expect(try Data(contentsOf: file) == Data("not json".utf8), "the settings app replaced the unreadable list")
        #expect((try FileManager.default.contentsOfDirectory(atPath: d.path)).filter { $0.hasPrefix("library-unreadable") }.isEmpty)
    }

    @Test func passiveStoreNeverMountsOrWatches() {
        let d = dir()
        Store(directory: d).add(URL(fileURLWithPath: "/Volumes/NAS/Film/FF_Dailies"), to: nil)
        let s = Store(directory: d, passive: true)
        let w = s.library.workspaces[0]
        s.mount(w)
        s.refresh()
        #expect(s.mounted.isEmpty && s.busy.isEmpty && s.errors.isEmpty, "the settings app tried to mount")
    }

    /// Läuft schon ein Selbsttest (in der App oder der Einstellungs-App), startet kein zweiter.
    @Test func secondSelfTestIsRefusedWhileOneRuns() {
        #expect(!SelfTest.runningAnywhere)
        let fd = open(SelfTest.lockPath, O_CREAT | O_RDWR, 0o644)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        let t = SelfTest()
        #expect(!t.start() && t.blocked && t.phase == .idle)
        #expect(SelfTest.runningAnywhere, "an update would start during the self-test")
    }

    /// Die Wächter des Selbsttests überschreiben die gespeicherten Bestätigungen von Mountpoint nicht.
    @Test func selfTestGuardsDoNotPersist() {
        let before = defaults.stringArray(forKey: "bigKnown")
        defer { if let before { defaults.set(before, forKey: "bigKnown") } else { defaults.removeObject(forKey: "bigKnown") } }
        defaults.set(["/kept"], forKey: "bigKnown")
        let guardian = VolumeGuard(names: { [] }, numbered: { [] }, sizeRoots: { [] }, persist: false)
        guardian.acknowledgeSize("/Volumes/MPSelftest-Size/Avid MediaFiles/MXF/1")
        #expect(defaults.stringArray(forKey: "bigKnown") == ["/kept"])
    }

    /// Ohne laufende Mountpoint: Schalter geht zurück, das Fenster sagt warum.
    @Test func launchAtLoginRevertsWhenMountpointDoesNotAnswer() async throws {
        let s = Store(directory: dir(), passive: true)
        let before = s.launchAtLogin
        s.setLaunchAtLogin(!before)
        #expect(s.launchAtLogin == !before)
        try await Task.sleep(nanoseconds: 3_300_000_000)
        #expect(s.launchAtLogin == before && s.notice != nil)
        // eine späte Antwort setzt den Schalter und nimmt den Hinweis weg
        s.launchAtLoginResult(on: !before, error: "", request: "late")
        #expect(s.launchAtLogin == !before && s.notice == nil)
        // die Antwort auf den offenen Auftrag zeigt den echten Zustand und den Fehler; fremde Antworten nicht
        s.setLaunchAtLogin(true)
        s.launchAtLoginResult(on: false, error: "spoofed", request: "other")
        #expect(s.launchAtLogin && s.notice == nil)
        s.launchAtLoginResult(on: false, error: "approve it", request: s.pendingLoginID ?? "")
        #expect(!s.launchAtLogin && s.notice == "approve it")
    }

    /// Zweimal schnell getippt, keine Antwort: zurück auf den bestätigten Zustand, nicht auf den vom ersten Tippen.
    @Test func launchAtLoginRevertsToTheConfirmedState() async throws {
        let s = Store(directory: dir(), passive: true)
        s.launchAtLoginResult(on: false, error: "", request: "")
        s.setLaunchAtLogin(true)
        s.setLaunchAtLogin(false)
        s.setLaunchAtLogin(true)
        try await Task.sleep(nanoseconds: 3_300_000_000)
        #expect(!s.launchAtLogin)
    }

    /// Der Schalter räumt nur seinen eigenen Hinweis weg – nicht z. B. „schreibgeschützt“.
    @Test func launchAtLoginKeepsOtherNotices() {
        let s = Store(directory: dir(), passive: true)
        s.notice = Store.readOnlyText
        s.setLaunchAtLogin(true)
        #expect(s.notice == Store.readOnlyText)
    }

    /// Verdrängt ein Fehler zum Startobjekt den Schreibschutz-Hinweis, kommt dieser zurück, sobald jener erledigt ist.
    @Test func readOnlyNoticeReturnsAfterALoginNotice() throws {
        let d = dir()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: d.appendingPathComponent("library.json"))
        let s = Store(directory: d, passive: true)
        s.setLaunchAtLogin(true)
        s.launchAtLoginResult(on: false, error: "approve it", request: s.pendingLoginID ?? "")
        #expect(s.notice == "approve it")
        s.launchAtLoginResult(on: true, error: "", request: "")
        #expect(s.readOnly && s.notice == Store.readOnlyText)
    }
}
