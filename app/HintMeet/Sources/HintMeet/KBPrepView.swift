import AppKit
import SwiftUI

/// Venster "Documenten omzetten": tools/kb_prep.py met zijn opties, en de voortgang erbij.
struct KBPrepView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var task: ProgressTask
    @State private var source = ""
    @State private var project = ""
    @State private var projectEdited = false   // zelf getypt: dan niet meer de bronmap volgen
    @State private var force = false
    @State private var noOCR = false
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Bronmap", text: $source, prompt: Text("map met documenten"))
                    Button("Kies…") { chooseSource() }
                }
                TextField("Project", text: Binding(get: { project }, set: { project = $0; projectEdited = true }),
                          prompt: Text("naam van de kennisbank"))
                LabeledContent("Doel") {
                    Text(project.isEmpty ? "—" : "\(settings.kbRoot)/\(project)")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Section("Opties") {
                Toggle("Alles opnieuw omzetten (--force)", isOn: $force)
                    .help("Ook ongewijzigde bronnen; eigen schaduwbestanden die je hebt aangepast worden overschreven")
                Toggle("Zonder OCR (--no-ocr)", isOn: $noOCR)
                    .help("Gescande PDF-pagina's en afbeeldingen niet uitlezen; veel sneller")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Omzetten") {
                        task.startKBPrep(settings, source: source, project: project, force: force, noOCR: noOCR)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(task.isRunning || !valid)
                }
                TaskProgressView(task: task, tick: tick)
            }
            Text("Wijzigingen in de bronmap pak je later ook op met KB laden in het paneel; dat draait dezelfde stap.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onReceive(timer) { tick = $0 }
        .onAppear(perform: prefill)
        .onChange(of: source) { _, new in
            if !projectEdited { project = Self.projectName(for: new) }   // standaard: laatste deel van de bronmap
        }
    }

    private var valid: Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: source, isDirectory: &dir) && dir.boolValue
            && project.range(of: #"^[A-Za-z0-9][A-Za-z0-9._ -]*$"#, options: .regularExpression) != nil
    }

    /// Projectnaam uit de bronmap, zoals kb_prep zelf doet: de laatste mapnaam, met tekens die in een
    /// projectnaam niet mogen vervangen door een streepje.
    static func projectName(for source: String) -> String {
        let last = (source as NSString).lastPathComponent
        let cleaned = last.replacingOccurrences(of: #"[^A-Za-z0-9._ -]"#, with: "-", options: .regularExpression)
        return cleaned.replacingOccurrences(of: #"^[^A-Za-z0-9]+"#, with: "", options: .regularExpression)
    }

    /// Standaard: de bronmap van het (eerste) gekozen project, uit zijn manifest.
    private func prefill() {
        guard source.isEmpty, let name = settings.selectedProjects.first else { return }
        let manifest = URL(fileURLWithPath: settings.kbRoot).appendingPathComponent(name)
            .appendingPathComponent("_manifest.json")
        if let data = try? Data(contentsOf: manifest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let root = json["source_root"] as? String {
            source = root
            project = Self.projectName(for: root)
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Kies"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url.path   // de projectnaam volgt via onChange, tenzij je hem zelf hebt aangepast
    }
}
