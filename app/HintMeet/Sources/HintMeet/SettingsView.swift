import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var keys: [String: String] = [:]
    @State private var devices: [String] = []
    @State private var saved: Bool? = nil

    var body: some View {
        Form {
            Section("Knowledge Base") {
                LabeledContent("Projects") { ProjectMenu(settings: settings) }
                TextField("KB folder", text: $settings.kbRoot)
            }
            Section("Audio") {
                Picker("Your microphone", selection: $settings.mic) {
                    Text("System default").tag("")
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }
                Picker("System audio (online meeting)", selection: $settings.system) {
                    Text("None (microphone only)").tag("")
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }
                if !devices.contains(where: { $0.localizedCaseInsensitiveContains("blackhole") }) {
                    Text("For Teams/Zoom/Meet: install BlackHole (brew install --cask blackhole-2ch).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Report with action items afterwards", isOn: $settings.summary)
            }
            Section("API-keys (Keychain)") {
                ForEach(Settings.keyNames, id: \.self) { name in
                    SecureField(name, text: Binding(get: { keys[name] ?? "" }, set: { keys[name] = $0; saved = nil }))
                }
                HStack {
                    Button("Save") {
                        saved = keys.map { settings.setKey($0.key, $0.value) }.allSatisfy { $0 }
                    }
                    if saved == true { Text("Saved").font(.caption).foregroundStyle(.secondary) }
                    if saved == false { Text("Saving failed (Keychain)").font(.caption).foregroundStyle(.red) }
                }
            }
            Section("Pipeline") {
                TextField("hint-meet project folder", text: $settings.repoPath)
                Text(settings.backendReady ? "Python environment found" : "No .venv/bin/python in this folder")
                    .font(.caption).foregroundStyle(settings.backendReady ? Color.secondary : Color.orange)
                Button("Open Log") { NSWorkspace.shared.open(Backend.logURL) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            devices = Settings.inputDevices()
            for name in Settings.keyNames { keys[name] = settings.key(name) }
        }
    }
}
