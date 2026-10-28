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
        do {
            if FileManager.default.fileExists(atPath: target.path) {   // de dialoog vroeg al of vervangen mag
                _ = try FileManager.default.replaceItemAt(target, withItemAt: copyToTemp(source))
            } else {
                try FileManager.default.copyItem(at: source, to: target)
            }
        } catch {
            alert("Couldn't save the copy: \(error.localizedDescription)")
        }
    }

    /// replaceItemAt verplaatst: eerst een kopie maken, anders verdwijnt het origineel.
    private static func copyToTemp(_ source: URL) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: tmp)
        return tmp
    }

    private static func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Report not copied"
        a.informativeText = text
        a.runModal()
    }
}
