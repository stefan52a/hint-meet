import Foundation

/// Werken de API-keys? Bij het openen van het paneel en na Save in Settings: `hint-meet check-keys` (gratis
/// aanroepen, zie src/hint_meet/apierrors.py). Een meeting test ze bij de start zelf ook nog eens.
@MainActor
final class KeyCheck: ObservableObject {
    /// Gepost door Settings na het bewaren van de sleutels: dan opnieuw testen.
    static let keysChanged = Notification.Name("HintMeetKeysChanged")

    @Published private(set) var problems: [String] = []
    @Published private(set) var checking = false
    private var checkID = 0

    func run(_ settings: Settings) {
        guard settings.backendReady else { return }
        checkID += 1
        let id = checkID
        checking = true
        let p = Backend.pythonProcess(settings, ["-m", "hint_meet.cli", "check-keys"])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let found = json?["problems"] as? [String]
            let unchecked = json?["unchecked"] as? [String] ?? []
            Task { @MainActor in
                guard let self, self.checkID == id else { return }   // een nieuwere controle gaat voor
                self.checking = false
                guard let found else { return }   // geen antwoord (bv. geen netwerk): de vorige stand houden
                // een dienst onbereikbaar: wat er eerder over die sleutel bekend was, blijft staan
                let kept = self.problems.filter { p in unchecked.contains { p.hasPrefix($0) } && !found.contains(p) }
                self.problems = found + kept
            }
        }
        do { try p.run() } catch { checking = false }
    }
}
