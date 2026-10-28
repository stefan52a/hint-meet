import AppKit
import UniformTypeIdentifiers

/// Een kopie van het verslag ergens anders bewaren (bv. een gedeelde map). Het origineel blijft in de map
/// meetings van het project; de map die je kiest, onthoudt HintMeet voor de volgende keer.
@MainActor
enum ReportCopy {
    private static let dirKey = "reportCopyDir"

    static func save(_ path: String) {
        let source = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            alert("The report is no longer at \(source.path).")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save a Copy of the Report"
        panel.nameFieldStringValue = source.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: source.pathExtension) ?? .plainText]
        panel.canCreateDirectories = true
        if let dir = UserDefaults.standard.string(forKey: dirKey) { panel.directoryURL = URL(fileURLWithPath: dir) }
        panel.level = .floating   // het paneel van HintMeet zweeft: de dialoog moet erboven staan
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        UserDefaults.standard.set(target.deletingLastPathComponent().path, forKey: dirKey)
        guard target.standardizedFileURL != source.standardizedFileURL else { return }   // zelfde bestand: klaar
        // buiten de hoofddraad: een trage of weggevallen netwerkmap mag het paneel niet bevriezen
        Task.detached {
            do {
                try copy(source, to: target)
            } catch {
                await MainActor.run { alert("Couldn't save the copy: \(error.localizedDescription)") }
            }
        }
    }

    /// Eerst naast het doel kopiëren, dan op zijn plek zetten: een bestaand bestand (de dialoog vroeg al of het
    /// vervangen mag) blijft heel als het kopiëren halverwege faalt, ook op een andere schijf of netwerkmap.
    nonisolated private static func copy(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).hintmeet-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: staged)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        } catch {
            try? fm.removeItem(at: staged)   // geen halve of verborgen kopie achterlaten
            throw error
        }
    }

    private static func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Report not copied"
        a.informativeText = text
        a.runModal()
    }
}
