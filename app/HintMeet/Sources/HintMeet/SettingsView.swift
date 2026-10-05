import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var keys: [String: String] = [:]
    @State private var devices: [String] = []
    @State private var saved: Bool? = nil

    var body: some View {
        Form {
            Section("Kennisbank") {
                LabeledContent("Projecten") { ProjectMenu(settings: settings) }
                TextField("KB-map", text: $settings.kbRoot)
            }
            Section("Audio") {
                Picker("Jouw microfoon", selection: $settings.mic) {
                    Text("Systeemstandaard").tag("")
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }
                Picker("Systeemaudio (online meeting)", selection: $settings.system) {
                    Text("Geen (alleen microfoon)").tag("")
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }
                if !devices.contains(where: { $0.localizedCaseInsensitiveContains("blackhole") }) {
                    Text("Voor Teams/Zoom/Meet: installeer BlackHole (brew install --cask blackhole-2ch).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Verslag met actiepunten na afloop", isOn: $settings.summary)
            }
            Section("API-keys (Keychain)") {
                ForEach(Settings.keyNames, id: \.self) { name in
                    SecureField(name, text: Binding(get: { keys[name] ?? "" }, set: { keys[name] = $0; saved = nil }))
                }
                HStack {
                    Button("Bewaren") {
                        saved = keys.map { settings.setKey($0.key, $0.value) }.allSatisfy { $0 }
                    }
                    if saved == true { Text("Bewaard").font(.caption).foregroundStyle(.secondary) }
                    if saved == false { Text("Bewaren mislukt (Keychain)").font(.caption).foregroundStyle(.red) }
                }
            }
            Section("Pijplijn") {
                TextField("Projectmap hint-meet", text: $settings.repoPath)
                Text(settings.backendReady ? "Python-omgeving gevonden" : "Geen .venv/bin/python in deze map")
                    .font(.caption).foregroundStyle(settings.backendReady ? Color.secondary : Color.orange)
                Button("Logboek openen") { NSWorkspace.shared.open(Backend.logURL) }
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
