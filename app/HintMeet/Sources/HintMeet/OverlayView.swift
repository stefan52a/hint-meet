import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var store: HintStore
    let send: ([String: Any]) -> Void
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let hint = store.current {
                HintCard(hint: hint, rate: { r in
                    store.rate(hint.id, r)
                    send(["type": "feedback", "id": hint.id, "rating": r])
                })
            } else {
                Text(store.connected ? "Luistert…" : "Wacht op hint-meet (hint-meet live --ui)")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !store.earlier.isEmpty {
                Divider()
                ForEach(store.earlier) { h in
                    Text(h.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let last = store.utterances.last {
                Divider()
                Text("\(last.speaker): \(last.text)").font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            if let path = store.summaryPath {
                Button("Verslag met actiepunten openen") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onReceive(timer) { tick = $0 }   // laat ingetrokken hints na een paar seconden verdwijnen
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(store.connected ? (store.stopped ? Color.gray : Color.green) : Color.orange)
                .frame(width: 7, height: 7)
            Text("hint-meet").font(.caption.weight(.semibold))
            if !store.project.isEmpty { Text("· \(store.project)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if store.connected && !store.stopped {
                Button("Stop") { send(["type": "stop"]) }.buttonStyle(.borderless).font(.caption)
            }
        }
    }
}

struct HintCard: View {
    let hint: Hint
    let rate: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hint.text + (hint.state == .streaming ? " …" : ""))
                .font(.system(size: 15, weight: hint.state == .final ? .medium : .regular))
                .strikethrough(hint.state == .retracted)
                .foregroundStyle(hint.state == .retracted ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            switch hint.state {
            case .retracted:
                Text("Ingetrokken: \(hint.reason)").font(.caption).foregroundStyle(.orange)
            case .streaming:
                Text("bron wordt gecontroleerd").font(.caption).foregroundStyle(.secondary)
            case .final:
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(hint.sources, id: \.self) { s in
                            Button((s.ref as NSString).lastPathComponent) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: s.path))
                            }
                            .buttonStyle(.link).font(.caption).lineLimit(1).help(s.path)
                        }
                    }
                    Spacer()
                    Button("👍") { rate(1) }.buttonStyle(.borderless).opacity(hint.rating == -1 ? 0.3 : 1)
                    Button("👎") { rate(-1) }.buttonStyle(.borderless).opacity(hint.rating == 1 ? 0.3 : 1)
                }
            }
        }
    }
}
