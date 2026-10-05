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

    static let keyNames = ["ANTHROPIC_API_KEY", "TYPESAFE_API_KEY"]

    init() {
        repoPath = d.string(forKey: "repoPath") ?? Settings.guessRepo()
        kbRoot = d.string(forKey: "kbRoot") ?? (NSHomeDirectory() + "/KB_md")
        project = d.string(forKey: "project") ?? ""
        mic = d.string(forKey: "mic") ?? ""
        system = d.string(forKey: "system") ?? ""
        summary = d.object(forKey: "summary") as? Bool ?? true
    }

    /// De app staat in <repo>/app/build/HintMeet.app; de pijplijn draait uit <repo>/.venv.
    static func guessRepo() -> String {
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
