import AVFoundation
import Combine
import Foundation

/// Instellingen: wat in UserDefaults mag (paden, project, apparaten) en de keys via de Keychain.
@MainActor
final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var repoPath: String { didSet { d.set(repoPath, forKey: "repoPath") } }
    @Published var kbRoot: String { didSet { d.set(kbRoot, forKey: "kbRoot") } }
    @Published var project: String { didSet { d.set(project, forKey: "project") } }
    @Published var mic: String { didSet { d.set(mic, forKey: "mic") } }
    @Published var system: String { didSet { d.set(system, forKey: "system") } }
    @Published var summary: Bool { didSet { d.set(summary, forKey: "summary") } }
    /// Met wie je spreekt, per meeting; komt in de naam van het verslag. Bewust niet onthouden.
    @Published var partner = ""

    static let keyNames = ["ANTHROPIC_API_KEY", "TYPESAFE_API_KEY"]

    init() {
        repoPath = d.string(forKey: "repoPath") ?? Settings.guessRepo()
        kbRoot = d.string(forKey: "kbRoot") ?? (NSHomeDirectory() + "/KB_md")
        project = d.string(forKey: "project") ?? ""
        mic = d.string(forKey: "mic") ?? ""
        system = d.string(forKey: "system") ?? ""
        summary = d.object(forKey: "summary") as? Bool ?? true
    }

    /// Gekozen projecten; `project` bewaart ze als "Finance,acme" (zo gaat het ook naar --project).
    var selectedProjects: [String] {
        project.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Voor in knoppen en menu's: "Finance + acme".
    var projectLabel: String { selectedProjects.joined(separator: " + ") }

    func toggleProject(_ name: String) {
        var chosen = selectedProjects
        if let i = chosen.firstIndex(of: name) { chosen.remove(at: i) } else { chosen.append(name) }
        project = chosen.joined(separator: ",")
    }

    /// De pijplijn draait uit <repo>/.venv. build-app.sh zet het repo-pad in Info.plist (ook voor de kopie in
    /// ~/Applications); anders aannemen dat de app in <repo>/app/build/HintMeet.app staat.
    static func guessRepo() -> String {
        if let repo = Bundle.main.object(forInfoDictionaryKey: "HintMeetRepo") as? String, !repo.isEmpty { return repo }
        let repo = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.path
    }

    var python: String { repoPath + "/.venv/bin/python" }
    var backendReady: Bool { FileManager.default.isExecutableFile(atPath: python) }

    /// Projecten = mappen in KB_ROOT met een kb_prep-manifest of Markdown erin.
    var projects: [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: kbRoot) else { return [] }
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            let path = kbRoot + "/" + name
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
            return fm.fileExists(atPath: path + "/_manifest.json")
                || ((try? fm.contentsOfDirectory(atPath: path))?.contains { $0.hasSuffix(".md") } ?? false)
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Namen van invoerapparaten zoals CoreAudio ze noemt (zelfde namen als de pijplijn gebruikt).
    static func inputDevices() -> [String] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                       mediaType: .audio, position: .unspecified)
        return session.devices.map(\.localizedName).sorted()
    }

    func key(_ name: String) -> String { Keychain.get(name) ?? "" }
    @discardableResult
    func setKey(_ name: String, _ value: String) -> Bool {
        Keychain.set(name, value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
