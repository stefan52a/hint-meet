import Foundation

/// Meetings die zonder verslag eindigden (crash, geforceerd gestopt, Claude niet bereikbaar): op het startscherm
/// alsnog schrijven met `hint-meet report`. Bron: logs/live-….meta.json naast elk live-transcript
/// (zie src/hint_meet/summary.py); oudere transcripten zonder meta tellen niet mee.
@MainActor
final class PendingReports: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String          // pad van het transcript
        let project: String
        let info: String
        let started: Date
        let utterances: Int
    }
    enum Writing: Equatable { case busy, done(String), failed(String) }

    @Published private(set) var items: [Item] = []
    @Published private(set) var writing: [String: Writing] = [:]
    /// Ouder dan dit: niet meer aanbieden (dan is het verslag waarschijnlijk niet meer nodig).
    nonisolated static let maxAge: TimeInterval = 14 * 24 * 3600
    nonisolated static let minUtterances = 3   // korter: ook na een gewone meeting geen verslag
    nonisolated private static let maxItems = 5

    func scan(_ settings: Settings) {
        let logs = URL(fileURLWithPath: settings.repoPath).appendingPathComponent("logs")
        DispatchQueue.global(qos: .utility).async {
            let found = Self.find(in: logs)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // net geschreven: blijft staan met Open Report, tot de volgende keer
                    let written = self.items.filter { item in
                        if case .done = self.writing[item.id] { return !found.contains { $0.id == item.id } }
                        return false
                    }
                    self.items = written + found
                }
            }
        }
    }

    nonisolated private static func find(in logs: URL) -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        let cutoff = Date().addingTimeInterval(-maxAge)
        var items: [Item] = []
        for meta in files where meta.lastPathComponent.hasPrefix("live-") && meta.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: meta),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["summary"] as? Bool == true,                 // verslag was gewenst
                  json["report"] as? String == nil,                  // en is er niet
                  json["dismissed"] as? Bool != true,
                  let started = (json["started"] as? Double).map({ Date(timeIntervalSince1970: $0) }), started > cutoff
            else { continue }
            let name = meta.lastPathComponent.dropLast(".meta.json".count) + ".txt"
            let transcript = logs.appendingPathComponent(String(name))
            guard let text = try? String(contentsOf: transcript, encoding: .utf8) else { continue }
            let count = text.split(separator: "\n").filter { $0.hasPrefix("[") }.count
            guard count >= minUtterances else { continue }
            items.append(Item(id: transcript.path, project: json["project"] as? String ?? "",
                              info: json["info"] as? String ?? "", started: started, utterances: count))
        }
        return Array(items.sorted { $0.started > $1.started }.prefix(maxItems))
    }

    func write(_ item: Item, _ settings: Settings) {
        guard writing[item.id] != .busy, settings.backendReady else { return }
        writing[item.id] = .busy
        let ask = settings.askSaveReport
        let p = Backend.pythonProcess(settings, ["-m", "hint_meet.cli", "report", item.id])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            let json = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
            Task { @MainActor in
                if let path = json?["path"] as? String {
                    self?.writing[item.id] = .done(path)
                    if ask { ReportCopy.save(path) }   // Settings: meteen vragen waar een kopie heen moet
                } else {
                    self?.writing[item.id] = .failed(json?["error"] as? String ?? "Writing the report failed; see the log")
                }
            }
        }
        do { try p.run() } catch { writing[item.id] = .failed("Could not start: \(error.localizedDescription)") }
    }

    /// Niet meer aanbieden: in de meta vastleggen, zodat hij ook na een herstart weg blijft.
    func dismiss(_ item: Item) {
        items.removeAll { $0.id == item.id }
        let transcript = URL(fileURLWithPath: item.id)
        let meta = transcript.deletingPathExtension().appendingPathExtension("meta.json")
        guard let data = try? Data(contentsOf: meta),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["dismissed"] = true
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? out.write(to: meta, options: .atomic)
        }
    }
}
