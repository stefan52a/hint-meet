import AppKit
import SwiftUI

/// Linkerkolom: wat er gezegd is en door het dossier onderbouwd wordt, op volgorde, met de bron erbij.
/// Volgt live de nieuwste bevestiging, tenzij je zelf omhoog gescrold hebt.
struct ConfirmList: View {
    @ObservedObject var store: HintStore
    /// Onderaan = live: een nieuwe bevestiging scrollt in beeld.
    @State private var atBottom = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Backed by the knowledge base", systemImage: "checkmark.seal")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if store.confirmations.isEmpty {
                Text("What is said and matches the documents appears here, with its source.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(store.confirmations) { c in
                                card(c).id(c.id)
                            }
                            Color.clear.frame(height: 1)
                                .onAppear { atBottom = true }
                                .onDisappear { atBottom = false }
                        }
                        .padding(.trailing, 6)
                    }
                    .onChange(of: store.confirmations.last?.id) { _, last in
                        if atBottom, let last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) } }
                    }
                    .onAppear { if let last = store.confirmations.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
        }
    }

    private func card(_ c: Confirmation) -> some View {
        let u = store.transcript.first { $0.id == c.id }
        return VStack(alignment: .leading, spacing: 4) {
            if let u {   // wat er gezegd is, klein; de bevestiging zelf valt op
                (Text(u.time + "  ").monospacedDigit() + Text(u.speaker + ": ").fontWeight(.semibold) + Text(u.text))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(c.text).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(c.sources, id: \.self) { s in
                Button((s.ref as NSString).lastPathComponent) { NSWorkspace.shared.open(URL(fileURLWithPath: s.path)) }
                    .buttonStyle(.link).font(.caption).lineLimit(1).help(s.path)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
