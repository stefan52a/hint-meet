import AppKit
import SwiftUI

/// Venster "Documenten omzetten": tools/kb_prep.py met zijn opties, en de voortgang erbij.
struct KBPrepView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var task: ProgressTask
    /// Vooraf ingevuld (bv. via HINT_MEET_CONVERT voor een demo): gaat voor het manifest van het gekozen project.
    var initialSource: String?
    var initialProject: String?
    @State private var source = ""
    @State private var project = ""
    @State private var projectEdited = false   // zelf getypt: dan niet meer de bronmap volgen
    @State private var prefilledSource = ""     // bronmap uit het manifest: die hoort bij de bestaande KB
    @State private var prefilledProject = ""
    @State private var force = false
    @State private var noOCR = false
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Source folder", text: $source, prompt: Text("folder with documents"))
                    Button("Choose…") { chooseSource() }
                }
                TextField("Project", text: Binding(get: { project }, set: { project = $0; projectEdited = true }),
                          prompt: Text("name of the knowledge base"))
                LabeledContent("Destination") {
                    Text(project.isEmpty ? "—" : "\(settings.kbRoot)/\(project)")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Section("Options") {
                Toggle("Convert everything again (--force)", isOn: $force)
                    .help("Also unchanged sources; converted files you edited yourself are overwritten")
                Toggle("Without OCR (--no-ocr)", isOn: $noOCR)
                    .help("Don't read scanned PDF pages and images; much faster")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Convert") {
                        task.startKBPrep(settings, source: source, project: project, force: force, noOCR: noOCR)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(task.isRunning || !valid)
                }
                TaskProgressView(task: task, tick: tick)
            }
            Text("Later changes in the source folder are also picked up by Preload KB in the panel; it runs the same step.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onReceive(timer) { tick = $0 }
        .onAppear(perform: prefill)
        .onChange(of: source) { _, new in
            // standaard: laatste deel van de bronmap; behalve de bronmap van de bestaande KB zelf
            if !projectEdited { project = new == prefilledSource ? prefilledProject : Self.projectName(for: new) }
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
        if source.isEmpty, let s = initialSource {
            source = s
            project = initialProject ?? Self.projectName(for: s)
            projectEdited = initialProject != nil
            return
        }
        guard source.isEmpty, let name = settings.selectedProjects.first else { return }
        let manifest = URL(fileURLWithPath: settings.kbRoot).appendingPathComponent(name)
            .appendingPathComponent("_manifest.json")
        if let data = try? Data(contentsOf: manifest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let root = json["source_root"] as? String {
            prefilledSource = root
            prefilledProject = name
            source = root
            project = name   // de bestaande KB bijwerken, ook als die anders heet dan de bronmap
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url.path   // de projectnaam volgt via onChange, tenzij je hem zelf hebt aangepast
    }
}
