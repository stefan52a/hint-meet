import AVFoundation
import Combine
import Foundation
import HintMeetCore

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
    /// De audio van de meeting bewaren, naast het transcript in logs/ (live-….mp3; WAV tijdens de meeting).
    @Published var saveAudio: Bool { didSet { d.set(saveAudio, forKey: "saveAudio") } }
    /// Is het verslag klaar, dan meteen vragen waar een kopie heen moet (naast die in de map van het project).
    @Published var askSaveReport: Bool { didSet { d.set(askSaveReport, forKey: "askSaveReport") } }
    /// Taal van het gesprek (een Whisper-code zoals "nl" of "en", of "multi"); hints en verslag volgen die taal.
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    /// Gevoeligheid (0 = minder, 1 = meer, 0,5 = gate.yaml): hints en correcties rechts, onderbouwing links.
    @Published var hintSensitivity: Double { didSet { d.set(hintSensitivity, forKey: "hintSensitivity") } }
    @Published var confirmSensitivity: Double { didSet { d.set(confirmSensitivity, forKey: "confirmSensitivity") } }
    /// Telefoon-companion toestaan: de gateway luistert dan op het Tailscale-adres (standaard uit).
    @Published var phoneEnabled: Bool { didSet { d.set(phoneEnabled, forKey: "phoneEnabled") } }
    /// Ook als HintMeet dicht is: een achtergronddienst (HintMeetWaker) start de app als de telefoon aanklopt.
    @Published var phoneWake: Bool { didSet { d.set(phoneWake, forKey: "phoneWake") } }
    /// Multilingual eerst, dan alle talen van Whisper alfabetisch (typ in het open menu de eerste letter).
    /// Gelijk aan src/hint_meet/languages.py.
    static let languages: [(code: String, name: String)] = [
        ("multi", "Multilingual"),
        ("af", "Afrikaans"),
        ("sq", "Albanian"),
        ("am", "Amharic"),
        ("ar", "Arabic"),
        ("hy", "Armenian"),
        ("as", "Assamese"),
        ("az", "Azerbaijani"),
        ("ba", "Bashkir"),
        ("eu", "Basque"),
        ("be", "Belarusian"),
        ("bn", "Bengali"),
        ("bs", "Bosnian"),
        ("br", "Breton"),
        ("bg", "Bulgarian"),
        ("yue", "Cantonese"),
        ("ca", "Catalan"),
        ("zh", "Chinese"),
        ("hr", "Croatian"),
        ("cs", "Czech"),
        ("da", "Danish"),
        ("nl", "Dutch"),
        ("en", "English"),
        ("et", "Estonian"),
        ("fo", "Faroese"),
        ("fi", "Finnish"),
        ("fr", "French"),
        ("gl", "Galician"),
        ("ka", "Georgian"),
        ("de", "German"),
        ("el", "Greek"),
        ("gu", "Gujarati"),
        ("ht", "Haitian Creole"),
        ("ha", "Hausa"),
        ("haw", "Hawaiian"),
        ("he", "Hebrew"),
        ("hi", "Hindi"),
        ("hu", "Hungarian"),
        ("is", "Icelandic"),
        ("id", "Indonesian"),
        ("it", "Italian"),
        ("ja", "Japanese"),
        ("jw", "Javanese"),
        ("kn", "Kannada"),
        ("kk", "Kazakh"),
        ("km", "Khmer"),
        ("ko", "Korean"),
        ("lo", "Lao"),
        ("la", "Latin"),
        ("lv", "Latvian"),
        ("ln", "Lingala"),
        ("lt", "Lithuanian"),
        ("lb", "Luxembourgish"),
        ("mk", "Macedonian"),
        ("mg", "Malagasy"),
        ("ms", "Malay"),
        ("ml", "Malayalam"),
        ("mt", "Maltese"),
        ("mi", "Maori"),
        ("mr", "Marathi"),
        ("mn", "Mongolian"),
        ("my", "Myanmar"),
        ("ne", "Nepali"),
        ("no", "Norwegian"),
        ("nn", "Nynorsk"),
        ("oc", "Occitan"),
        ("ps", "Pashto"),
        ("fa", "Persian"),
        ("pl", "Polish"),
        ("pt", "Portuguese"),
        ("pa", "Punjabi"),
        ("ro", "Romanian"),
        ("ru", "Russian"),
        ("sa", "Sanskrit"),
        ("sr", "Serbian"),
        ("sn", "Shona"),
        ("sd", "Sindhi"),
        ("si", "Sinhala"),
        ("sk", "Slovak"),
        ("sl", "Slovenian"),
        ("so", "Somali"),
        ("es", "Spanish"),
        ("su", "Sundanese"),
        ("sw", "Swahili"),
        ("sv", "Swedish"),
        ("tl", "Tagalog"),
        ("tg", "Tajik"),
        ("ta", "Tamil"),
        ("tt", "Tatar"),
        ("te", "Telugu"),
        ("th", "Thai"),
        ("bo", "Tibetan"),
        ("tr", "Turkish"),
        ("tk", "Turkmen"),
        ("uk", "Ukrainian"),
        ("ur", "Urdu"),
        ("uz", "Uzbek"),
        ("vi", "Vietnamese"),
        ("cy", "Welsh"),
        ("yi", "Yiddish"),
        ("yo", "Yoruba"),
    ]
    /// Meeting-info (met wie, waar, …), per meeting; komt in de naam van het verslag. Bewust niet onthouden.
    @Published var meetingInfo = ""

    static let keyNames = ["ANTHROPIC_API_KEY", "TYPESAFE_API_KEY"]

    init() {
        repoPath = d.string(forKey: "repoPath") ?? Settings.guessRepo()
        kbRoot = d.string(forKey: "kbRoot") ?? (NSHomeDirectory() + "/KB_md")
        project = d.string(forKey: "project") ?? ""
        mic = d.string(forKey: "mic") ?? ""
        system = d.string(forKey: "system") ?? ""
        summary = d.object(forKey: "summary") as? Bool ?? true
        saveAudio = d.object(forKey: "saveAudio") as? Bool ?? true
        askSaveReport = d.bool(forKey: "askSaveReport")
        language = d.string(forKey: "language") ?? "nl"
        hintSensitivity = d.object(forKey: "hintSensitivity") as? Double ?? 0.5
        confirmSensitivity = d.object(forKey: "confirmSensitivity") as? Double ?? 0.5
        phoneEnabled = d.bool(forKey: "phoneEnabled")
        phoneWake = d.object(forKey: "phoneWake") as? Bool ?? true
    }

    /// Voor de lopende meeting (zie "sensitivity" in src/hint_meet/server.py).
    var sensitivityMessage: [String: Any] {
        ["type": "sensitivity", "hints": hintSensitivity, "confirm": confirmSensitivity]
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

    /// Sleutel van de gekoppelde telefoon, in een bestand naast ws-token (alleen voor jou leesbaar), niet in de
    /// Keychain: zo vraagt macOS nergens om toestemming. Bestaat hij nog niet, dan maakt de eerste vraag er een.
    static let phoneTokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/hint-meet/phone-token")

    /// Leeg als het bestand niet te schrijven is: dan komt geen enkele telefoon binnen en is er geen QR.
    var phoneToken: String {
        if GatewayTestMode.active { return GatewayTestMode.phoneToken }
        if let t = try? String(contentsOf: Self.phoneTokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        let t = PhoneAuth.newToken()
        return Self.savePhoneToken(t) ? t : ""
    }

    /// Nieuwe koppeling: de oude telefoon komt er niet meer in. nil als het bestand niet geschreven kon worden
    /// (dan blijft de oude sleutel staan).
    func renewPhoneToken() -> String? {
        if GatewayTestMode.active { return GatewayTestMode.phoneToken }
        let t = PhoneAuth.newToken()
        return Self.savePhoneToken(t) ? t : nil
    }

    private static func savePhoneToken(_ token: String) -> Bool {
        let fm = FileManager.default
        let dir = phoneTokenURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent("phone-token.\(getpid()).tmp")
            guard fm.createFile(atPath: tmp.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
            else { return false }
            if fm.fileExists(atPath: phoneTokenURL.path) {
                _ = try fm.replaceItemAt(phoneTokenURL, withItemAt: tmp)   // in één keer, nooit half
            } else {
                try fm.moveItem(at: tmp, to: phoneTokenURL)                // replaceItemAt wil een bestaand doel
            }
            return true
        } catch {
            return false
        }
    }

    /// Waarde uit de .env in de projectmap (zelfde bestand als de pijplijn leest), of nil.
    func envFileValue(_ name: String) -> String? {
        guard let text = try? String(contentsOfFile: repoPath + "/.env", encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == name else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let q = value.first, q == "\"" || q == "'" {
                // tussen aanhalingstekens: tot het sluitende teken, een opmerking erachter telt niet mee
                let rest = value.dropFirst()
                value = rest.firstIndex(of: q).map { String(rest[..<$0]) } ?? String(rest)
            } else if let hash = value.range(of: " #") {   // KEY=waarde  # opmerking (zoals python-dotenv)
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Een sleutel uit de .env gaat voor: dan blijft de Keychain dicht (geen toestemmingsvragen van macOS).
    func key(_ name: String) -> String {
        if let v = envFileValue(name) { return v }
        return keychainKey(name)
    }

    /// Alleen wat in de Keychain staat (voor het veld in de instellingen).
    func keychainKey(_ name: String) -> String { GatewayTestMode.active ? "" : Keychain.get(name) ?? "" }

    @discardableResult
    func setKey(_ name: String, _ value: String) -> Bool {
        Keychain.set(name, value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
