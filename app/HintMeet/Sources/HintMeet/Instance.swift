import Foundation

/// Meerdere HintMeets naast elkaar (bv. twee meetings tegelijk). Elke instantie claimt het laagste vrije
/// nummer met een slot dat macOS vanzelf vrijgeeft als het proces stopt. Nummer 1 houdt poort 8765 en de
/// bestaande namen; nummer 2 krijgt poort 8766, "backend-2.log", eigen vensterplekken, enzovoort.
enum Instance {
    static let number: Int = claim()

    /// Poort van de pijplijn van deze instantie (HINT_MEET_PORT gaat voor, voor tests).
    static var port: Int { Int(ProcessInfo.processInfo.environment["HINT_MEET_PORT"] ?? "") ?? 8765 + number - 1 }

    /// "overlayFrame" → "overlayFrame.2": vensterplekken per instantie.
    static func key(_ base: String) -> String { number == 1 ? base : "\(base).\(number)" }

    /// "backend" → "backend-2": logboeken per instantie.
    static func name(_ base: String) -> String { number == 1 ? base : "\(base)-\(number)" }

    /// Achter titels en het 💡-icoon, zodat je de vensters uit elkaar houdt.
    static var suffix: String { number == 1 ? "" : " \(number)" }

    private static func claim() -> Int {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/hint-meet/instances")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in 1...20 {
            let fd = open(dir.appendingPathComponent("\(n).lock").path, O_RDWR | O_CREAT, 0o600)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return n }   // fd blijft open: het slot geldt zolang de app draait
            close(fd)
        }
        return 1   // geen slot te krijgen: gewoon als eerste instantie verder
    }
}
