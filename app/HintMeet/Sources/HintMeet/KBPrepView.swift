import AppKit
import SwiftUI

/// Venster "Documenten omzetten": tools/kb_prep.py met zijn opties, en de voortgang erbij.
struct KBPrepView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var task: ProgressTask
    @State private var source = ""
    @State private var project = ""
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
                TextField("Project", text: $project, prompt: Text("naam van de kennisbank"))
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
    }

    private var valid: Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: source, isDirectory: &dir) && dir.boolValue
            && project.range(of: #"^[A-Za-z0-9][A-Za-z0-9._ -]*$"#, options: .regularExpression) != nil
    }

    /// Standaard: de bronmap van het (eerste) gekozen project, uit zijn manifest.
    private func prefill() {
        guard source.isEmpty, let name = settings.selectedProjects.first else { return }
        project = name
        let manifest = URL(fileURLWithPath: settings.kbRoot).appendingPathComponent(name)
            .appendingPathComponent("_manifest.json")
        if let data = try? Data(contentsOf: manifest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let root = json["source_root"] as? String {
            source = root
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Kies"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url.path
        if project.isEmpty || !settings.projects.contains(project) {
            project = url.lastPathComponent   // zoals kb_prep zelf: de naam van de bronmap
        }
    }
}
