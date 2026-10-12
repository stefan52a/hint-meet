import SwiftUI

/// Klein schuifje boven een kolom: minder ↔ meer. Midden = de waarden uit config/gate.yaml.
struct SensitivitySlider: View {
    let title: String
    @Binding var value: Double
    let help: String
    let changed: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).fixedSize()
            Text("Fewer").font(.caption2).foregroundStyle(.tertiary)
            // pas na loslaten versturen: tijdens het slepen niet elke tussenstand naar de pijplijn
            Slider(value: $value, in: 0...1) { editing in if !editing { changed() } }
                .controlSize(.mini)
                .frame(minWidth: 60, maxWidth: 140)
            Text("More").font(.caption2).foregroundStyle(.tertiary)
            Button { value = 0.5; changed() } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless).font(.caption2).opacity(abs(value - 0.5) < 0.01 ? 0 : 1)
                .help("Back to the default (config/gate.yaml)")
        }
        .help(help)
    }
}
