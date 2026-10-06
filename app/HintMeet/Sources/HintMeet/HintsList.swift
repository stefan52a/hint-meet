import SwiftUI

/// Alle hints van de meeting op volgorde, scrollbaar. De geselecteerde hint staat groot in het midden, de
/// andere compact en gedimd. Scrollen selecteert de hint in het midden (het transcript scrollt mee);
/// een selectie vanuit het transcript of de pijltjes scrollt deze lijst mee.
struct HintsList: View {
    @ObservedObject var store: HintStore
    let rate: (Int, Int) -> Void
    @State private var ignoreScrollUntil = Date.distantPast
    /// Scrollpositie bij de vorige meting: alleen echt scrollen kiest een andere hint.
    @State private var lastOffset: CGFloat?

    var body: some View {
        let focus = store.shown?.id
        let items = store.listHints
        GeometryReader { viewport in
            let pad = max(viewport.size.height / 2 - 60, 0)   // ruimte zodat ook de eerste en laatste in het midden kunnen
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Color.clear.frame(height: pad)
                        ForEach(items) { h in
                            card(h, selected: h.id == focus)
                                .id(h.id)
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: HintFrames.self, value: [h.id: g.frame(in: .named("hints"))])
                                })
                                .onTapGesture { if h.id != focus { store.browse(to: h.id, from: .other) } }
                        }
                        Color.clear.frame(height: pad)
                    }
                    .padding(.trailing, 6)
                    .background(GeometryReader { g in   // de hele inhoud: zijn positie is de scrollpositie
                        Color.clear.preference(key: HintFrames.self, value: [Int.min: g.frame(in: .named("hints"))])
                    })
                }
                .coordinateSpace(name: "hints")
                .onPreferenceChange(HintFrames.self) { frames in follow(frames, height: viewport.size.height) }
                .onChange(of: focus) { _, id in   // hint gekozen door te scrollen in het transcript
                    guard store.selectionSource == .transcript, let id else { return }
                    scroll(proxy, to: id, animated: true)
                }
                .onChange(of: store.revealToken) { _, _ in   // jouw keuze (klik, ◀ ▶, Latest): die hint in het midden
                    if let id = store.shown?.id { scroll(proxy, to: id, animated: true) }
                }
                .onChange(of: items.last?.id) { _, last in   // nieuwe hint terwijl je live meeleest
                    if !store.isBrowsing, let last { scroll(proxy, to: last, animated: true) }
                }
                .onAppear { if let id = focus { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    @ViewBuilder private func card(_ h: Hint, selected: Bool) -> some View {
        if selected {
            HintCard(hint: h, rate: { rate(h.id, $0) })
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(OverlayView.clock.string(from: h.updated)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                Text(HintCard.bullets(h.text)).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .opacity(0.75)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows this hint and its utterance in the transcript")
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: Int, animated: Bool) {
        ignoreScrollUntil = Date().addingTimeInterval(0.5)
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// De hint die het dichtst bij het midden staat wordt de geselecteerde; met een drempel, zodat de
    /// selectie niet heen en weer springt als de grote kaart van hoogte verandert.
    private func follow(_ all: [Int: CGRect], height: CGFloat) {
        let offset = all[Int.min]?.minY
        var frames = all
        frames[Int.min] = nil
        defer { lastOffset = offset }
        let scrolled = offset != nil && lastOffset != nil && abs(offset! - lastOffset!) > 0.5
        guard scrolled, Date() >= ignoreScrollUntil else { return }   // een klik of een kaart die groeit is geen scrollen
        let middle = height / 2
        let visible = frames.filter { $0.value.maxY > 0 && $0.value.minY < height }
        // live blijft live zolang de nieuwste hint in beeld is: een nieuwe kaart of een kaart die van
        // hoogte verandert is geen omhoog scrollen; pas als je de nieuwste uit beeld scrolt ga je bladeren
        if !store.isBrowsing, let newest = store.listHints.last?.id, visible[newest] != nil { return }
        guard let best = visible.min(by: { abs($0.value.midY - middle) < abs($1.value.midY - middle) })?.key,
              best != store.shown?.id else { return }
        if let current = store.shown?.id, let now = visible[current], let next = visible[best],
           abs(now.midY - middle) - abs(next.midY - middle) < 40 { return }
        if best == store.listHints.last?.id || best == store.current?.id {
            store.latest(from: .hints)   // de nieuwste in het midden: weer live
        } else {
            store.browse(to: best, from: .hints)
        }
    }
}

/// Posities van de hints in de hintlijst.
private struct HintFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
