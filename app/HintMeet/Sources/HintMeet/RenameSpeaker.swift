import AppKit
import SwiftUI

/// Klein venster om een spreker te hernoemen ("Speaker 1" → "Jan"). Een eigen venster omdat het paneel tijdens een
/// meeting bewust geen toetsenbord aanneemt; na afloop krijgt de meeting-app de focus terug.
struct RenameSpeakerView: View {
    let old: String
    let canRemember: Bool
    let done: (_ name: String?, _ remember: Bool) -> Void
    @State private var name = ""
    @State private var remember = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(old)").font(.headline)
            TextField("Name, e.g. Jan", text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { finish() }
            if canRemember {
                Toggle("Remember this voice for next meetings", isOn: $remember)
                    .help("HintMeet then recognizes this person by name from the start of the next meeting")
            }
            Text("All earlier and later utterances of \(old) get this name, also in the report.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { done(nil, false) }.keyboardShortcut(.cancelAction)
                Button("Rename") { finish() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func finish() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        done(n, remember)
    }
}
