import AppKit
import Foundation

/// Schickt Selbsttest-Berichte und Problem-Meldungen an den Empfänger (Cloudflare Worker, worker/ im Repo), der sie als
/// Issue in einem privaten GitHub-Repo ablegt. Kein Schlüssel in der App: der Worker begrenzt und prüft selbst.
/// Klappt das Senden nicht, liegt der Bericht als Datei in „Downloads“ – nichts geht verloren.
enum Reporter {
    /// Empfänger (Worker). Leer = noch nicht eingerichtet → nur speichern.
    static let endpoint = URL(string: "https://mountpoint-reports.moritz-poth.workers.dev/report")

    enum Outcome: Equatable { case sent(String), saved(String), failed(String) }

    static func encode(_ report: SelfTestReport) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(report)) ?? Data()
    }

    /// Senden; bei einem Fehler als Datei sichern und den Ort melden.
    static func send(_ report: SelfTestReport) async -> Outcome {
        let body = encode(report)
        if let endpoint {
            var req = URLRequest(url: endpoint, timeoutInterval: 30)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Mountpoint/\(report.app)", forHTTPHeaderField: "User-Agent")
            req.httpBody = body
            if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
                let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String ?? ""
                Log.write("report sent: \(report.kind) \(id)")
                return .sent(id)
            }
        }
        switch save(report) {
        case .saved(let path): Log.write("report saved (sending failed): \(path)"); return .failed(path)
        case let other: return other
        }
    }

    /// Als Datei in „Downloads“ sichern und im Finder zeigen.
    @discardableResult
    static func save(_ report: SelfTestReport, reveal: Bool = false) -> Outcome {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("Mountpoint-\(report.kind)-\(f.string(from: Date())).json")
        do {
            try encode(report).write(to: url)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return .saved(url.path)
        } catch {
            return .failed("")
        }
    }

    /// Problem-Meldung: Beschreibung, optional Kontakt, optional Systeminfo und Log (anonymisiert).
    @MainActor static func problem(text: String, contact: String, attach: Bool) -> SelfTestReport {
        SelfTestReport(kind: "problem", app: Updater.current, build: SelfTest.build, date: ISO8601DateFormatter().string(from: Date()),
                       system: attach ? SelfTest.systemInfo() : [:], results: [], durationSeconds: 0,
                       log: attach ? SelfTest.logTail() : [], note: text, contact: contact.isEmpty ? nil : contact)
    }
}
