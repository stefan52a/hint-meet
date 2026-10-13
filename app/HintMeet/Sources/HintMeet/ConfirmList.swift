import AppKit
import SwiftUI

/// Linkerkolom: wat er gezegd is en door het dossier onderbouwd wordt, op volgorde, met de bron erbij.
/// Net als de hintlijst: live staat de nieuwste in het midden; scroll je omhoog of kies je er een (hier of via
/// de ✓ in het transcript), dan staat die in het midden met de latere eronder.
struct ConfirmList: View {
    @ObservedObject var store: HintStore
    /// Helemaal naar onderen gescrold (de nieuwste in het midden): nieuwe bevestigingen scrollen mee.
    @State private var pinned = true
    @State private var ignoreScrollUntil = Date.distantPast
    /// Scrollpositie bij de vorige meting: alleen echt scrollen telt (niet een kaart die erbij komt).
    @State private var lastOffset: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.confirmations.isEmpty {
                Text("✓ What is said and matches the documents, and 📄 what they say about the topic, with the source.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                let focus = store.backedID ?? store.confirmations.last?.id
                GeometryReader { viewport in
                    let pad = max(viewport.size.height / 2 - 50, 0)   // zodat ook de eerste en laatste in het midden kunnen
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                Color.clear.frame(height: pad)
                                ForEach(store.confirmations) { c in
                                    card(c, focused: c.id == focus).id(c.id)
                                        .onTapGesture { store.selectBacked(c.id, fromTranscript: false) }
                                }
                                Color.clear.frame(height: pad)
                            }
                            .padding(.trailing, 6)
                            .background(GeometryReader { g in   // de inhoud t.o.v. het venster: scrollpositie en onderkant
                                Color.clear.preference(key: ContentFrame.self, value: g.frame(in: .named("backed")))
                            })
                        }
                        .coordinateSpace(name: "backed")
                        .onPreferenceChange(ContentFrame.self) { frame in follow(frame, height: viewport.size.height) }
                        .onChange(of: store.confirmations) { _, list in
                            if pinned, store.backedID == nil, let last = list.last?.id { scroll(proxy, to: last) }
                        }
                        .onChange(of: store.backedToken) { _, _ in   // gekozen hier of via een ✓: in het midden
                            if let id = store.backedID { scroll(proxy, to: id) }
                        }
                        .onChange(of: store.backedID) { _, id in   // terug naar live: de nieuwste in het midden
                            if id == nil, let last = store.confirmations.last?.id { scroll(proxy, to: last) }
                        }
                        .onAppear {
                            if let id = store.backedID ?? store.confirmations.last?.id { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: Int) {
        ignoreScrollUntil = Date().addingTimeInterval(0.5)
        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
    }

    /// Onderaan = live. Zelf weer helemaal naar onderen scrollen heft een keuze op.
    private func follow(_ frame: CGRect, height: CGFloat) {
        let now = frame.maxY <= height + 8
        if now != pinned { pinned = now }
        defer { lastOffset = frame.minY }
        guard let last = lastOffset, abs(frame.minY - last) > 0.5, Date() >= ignoreScrollUntil else { return }
        if now { store.clearBacked() }
    }

    private func card(_ c: Confirmation, focused: Bool) -> some View {
        let u = store.transcript.first { $0.id == c.id }
        return VStack(alignment: .leading, spacing: 4) {
            if let u {   // wat er gezegd is, klein; de bevestiging zelf valt op
                (Text(u.time + "  ").monospacedDigit() + Text(u.speaker + ": ").fontWeight(.semibold) + Text(u.text))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // ✓ = wat gezegd is klopt; 📄 = wat het dossier over dit onderwerp zegt
                Image(systemName: c.confirms ? "checkmark.circle.fill" : "doc.text")
                    .foregroundStyle(c.confirms ? Color.green : Color.accentColor)
                    .help(c.confirms ? "What was said matches the documents" : "What the documents say about this")
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
        .background((c.confirms ? Color.green : Color.accentColor).opacity(focused ? 0.16 : 0.06),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(c.confirms ? Color.green : Color.accentColor, lineWidth: focused && store.backedID != nil ? 2 : 0))
        .opacity(focused ? 1 : 0.75)
        .contentShape(Rectangle())
        .help("Click to highlight this utterance in the transcript")
    }
}

/// De inhoud van een scrollview, in het assenstelsel van die scrollview.
private struct ContentFrame: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
