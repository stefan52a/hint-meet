import Foundation

/// Werken de API-keys? Bij het openen van het paneel en na Save in Settings: `hint-meet check-keys` (gratis
/// aanroepen, zie src/hint_meet/apierrors.py). Een meeting test ze bij de start zelf ook nog eens.
@MainActor
final class KeyCheck: ObservableObject {
    /// Gepost door Settings na het bewaren van de sleutels: dan opnieuw testen.
    static let keysChanged = Notification.Name("HintMeetKeysChanged")

    @Published private(set) var problems: [String] = []
    @Published private(set) var checking = false
    /// Telt op bij elke controle die over alle sleutels uitsluitsel gaf: dan is die de stand, ook tegenover oudere
    /// meldingen (van een vorige meeting).
    @Published private(set) var answered = 0
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
            let complete = (json?["unchecked"] as? [String])?.isEmpty ?? false
            Task { @MainActor in
                guard let self, self.checkID == id else { return }   // een nieuwere controle gaat voor
                self.checking = false
                guard let found else { return }   // geen antwoord (bv. geen netwerk): de vorige stand houden
                self.problems = found
                if complete { self.answered += 1 }   // een dienst onbereikbaar: oudere meldingen laten staan
            }
        }
        do { try p.run() } catch { checking = false }
    }
}
