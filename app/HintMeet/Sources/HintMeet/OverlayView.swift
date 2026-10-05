import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var store: HintStore
    @ObservedObject var backend: Backend
    @ObservedObject var settings: Settings
    @ObservedObject var layout: PanelLayout
    let send: ([String: Any]) -> Void
    let startMeeting: () -> Void
    let playRecording: () -> Void
    let stopMeeting: () -> Void
    let openSettings: () -> Void
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let hint = store.current {
                HintCard(hint: hint, rate: { r in
                    store.rate(hint.id, r)
                    send(["type": "feedback", "id": hint.id, "rating": r, "session": store.session])
                })
            } else {
                idle
            }
            if let r = store.justRetracted {
                // bewust klein en grijs: wat niet meer klopt hoort niet de aandacht te trekken
                Text("Ingetrokken (\(r.reason)): \(r.text)")
                    .font(.caption).strikethrough().foregroundStyle(.tertiary).lineLimit(1)
            }
            if !store.earlier.isEmpty {
                Divider()
                ForEach(store.earlier) { h in
                    Text(h.text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let last = store.utterances.last {
                Divider()
                Text("\(last.speaker): \(last.text)").font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
            if let path = store.summaryPath {
                Button("Verslag met actiepunten openen") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .frame(width: layout.width, alignment: .topLeading)
        .frame(minHeight: layout.minHeight, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onReceive(timer) { tick = $0 }   // laat het regeltje over een ingetrokken hint na een paar seconden verdwijnen
    }

    /// Geen hint in beeld: wat de pijplijn doet, of knoppen om te beginnen.
    @ViewBuilder private var idle: some View {
        switch backend.state {
        case .running:
            Text(store.connected ? (store.status.isEmpty ? "Luistert…" : store.status) : "Pijplijn start…")
                .font(.callout).foregroundStyle(.secondary)
        case .stopping:
            Text("Stopt… verslag wordt gemaakt").font(.callout).foregroundStyle(.secondary)
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 8) {
                if case .failed(let why) = backend.state {
                    Text(why).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Picker("Kennisbank", selection: $settings.project) {
                    Text("— kies een project —").tag("")
                    ForEach(settings.projects, id: \.self) { Text($0).tag($0) }
                }
                .controlSize(.small)
                if !settings.project.isEmpty {
                    HStack {
                        Button("Meeting starten · \(settings.project)") { startMeeting() }
                            .buttonStyle(.borderedProminent)
                        Button("Opname afspelen…") { playRecording() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(backend.state == .running ? (store.connected ? Color.green : Color.orange) : Color.gray)
                .frame(width: 7, height: 7)
            Text("hint-meet").font(.caption.weight(.semibold))
            if !store.project.isEmpty { Text("· \(store.project)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if backend.state == .running {
                Button("Stop") { stopMeeting() }.buttonStyle(.borderless).font(.caption)
            }
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Instellingen")
        }
    }
}

struct HintCard: View {
    let hint: Hint
    let rate: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // wat je kunt zeggen: groot, met een accentbalk ervoor zodat het in één blik te vinden is
            Text(hint.text + (hint.state == .streaming ? " …" : ""))
                .font(.system(size: 19, weight: hint.state == .final ? .semibold : .regular))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.vertical, 8).padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(hint.state == .final ? 0.14 : 0.06),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 4).padding(.vertical, 4)
                }
            switch hint.state {
            case .retracted:
                EmptyView()  // komt hier niet: ingetrokken hints staan als regeltje in de overlay
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
