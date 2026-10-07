import Foundation

/// Of de gekozen kennisbank(en) geladen moeten worden ("Load KB" alleen tonen als het nodig is): nog nooit met
/// succes geladen, of sindsdien iets veranderd in de bronmap of de kennisbank. Controle in de achtergrond,
/// die stopt bij de eerste wijziging.
@MainActor
final class KBStatus: ObservableObject {
    @Published private(set) var needsLoad = true
    private let settings: Settings
    private var checkID = 0

    init(settings: Settings) { self.settings = settings }

    private static func key(_ project: String) -> String { "preparedAt." + project }

    /// Na een geslaagde Load KB / Add Folder: deze projecten zijn bijgewerkt tot nu.
    func markLoaded(_ projects: [String]) {
        let now = Date().timeIntervalSince1970
        for p in projects { UserDefaults.standard.set(now, forKey: Self.key(p)) }
        needsLoad = false
    }

    func refresh() {
        checkID += 1
        let id = checkID
        let projects = settings.selectedProjects
        let kbRoot = settings.kbRoot
        let loadedAt = projects.map { UserDefaults.standard.double(forKey: Self.key($0)) }
        guard !projects.isEmpty else { needsLoad = false; return }
        DispatchQueue.global(qos: .utility).async {
            let needed = zip(projects, loadedAt).contains { project, at in
                Self.needsLoad(project: project, kbRoot: kbRoot, loadedAt: at)
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.checkID == id else { return }   // een nieuwere controle gaat voor
                    self.needsLoad = needed
                }
            }
        }
    }

    nonisolated private static func needsLoad(project: String, kbRoot: String, loadedAt: Double) -> Bool {
        guard loadedAt > 0 else { return true }   // nog nooit (met succes) geladen
        let kb = URL(fileURLWithPath: kbRoot).appendingPathComponent(project)
        let since = Date(timeIntervalSince1970: loadedAt)
        var dirs = [kb]
        if let data = try? Data(contentsOf: kb.appendingPathComponent("_manifest.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let source = json["source_root"] as? String {
            dirs.append(URL(fileURLWithPath: source))
        }
        return dirs.contains { changed(in: $0, since: since) }
    }

    /// Is er in deze map iets nieuwer dan `since`? Bestanden én mappen (een gekopieerd bestand houdt zijn oude
    /// datum, maar de map waarin het kwam niet); verborgen mappen (caches) tellen niet mee.
    nonisolated private static func changed(in dir: URL, since: Date) -> Bool {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        if let d = try? dir.resourceValues(forKeys: Set(keys)).contentModificationDate, d > since { return true }
        guard let items = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return false }
        for case let url as URL in items {
            if let d = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate, d > since { return true }
        }
        return false
    }
}
