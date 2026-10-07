import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var store: HintStore
    @ObservedObject var backend: Backend
    @ObservedObject var preparer: ProgressTask
    @ObservedObject var kbPrep: ProgressTask
    @ObservedObject var kbStatus: KBStatus
    @ObservedObject var settings: Settings
    @ObservedObject var layout: PanelLayout
    let send: ([String: Any]) -> Void
    let startMeeting: () -> Void
    let playRecording: () -> Void
    let stopMeeting: () -> Void
    let openSettings: () -> Void
    let addFolder: () -> Void
    let find: () -> Void
    @State private var tick = Date()
    @State private var size = CGSize(width: PanelLayout.defaultWidth, height: 560)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if backend.isRunning || !store.transcript.isEmpty { header }   // buiten een meeting: tandwiel in de KB-regel
            if backend.state == .stopping { stopping }
            // transcript en hints krijgen alle hoogte die het venster overlaat (geen vaste marges)
            if store.transcript.isEmpty && store.listHints.isEmpty {
                hintColumn(listHeight: nil)
            } else if size.width >= Self.twoColumnWidth {
                // links het gesprek, rechts de hints op volgorde; de uitspraak van de hint in het midden is gemarkeerd
                HStack(alignment: .top, spacing: 12) {
                    TranscriptView(store: store).frame(width: size.width * 0.45).frame(maxHeight: .infinity)
                    Divider()
                    hintColumn(listHeight: nil).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
            } else {
                hintColumn(listHeight: 200)
                Divider()
                TranscriptView(store: store).frame(maxHeight: .infinity)
            }
            if let path = store.summaryPath {
                Button("Open Report with Action Items") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // vult het venster
        .background(.regularMaterial)
        .background(GeometryReader { g in   // breedte en hoogte van het venster, voor de indeling
            Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s }
        })
        .onReceive(timer) { tick = $0 }   // laat het regeltje over een ingetrokken hint na een paar seconden verdwijnen
    }

    /// Vanaf deze breedte staan transcript en hint naast elkaar; smaller komt het transcript eronder.
    static let twoColumnWidth: CGFloat = 560


    /// Rechterkolom: bladeren en de hints op volgorde (of de knoppen om te beginnen), en intrekkingen.
    /// listHeight nil: de hintlijst vult de beschikbare hoogte; anders een vaste hoogte (smal venster).
    @ViewBuilder private func hintColumn(listHeight: CGFloat?) -> some View {
        let bar = store.history.count > 1 || store.isBrowsing
        VStack(alignment: .leading, spacing: 8) {
            if store.listHints.isEmpty {
                idle
            } else {
                if bar { historyBar }
                HintsList(store: store, rate: { id, r in
                    store.rate(id, r)
                    send(["type": "feedback", "id": id, "rating": r, "session": store.session])
                })
                .frame(height: listHeight)
                .frame(maxHeight: listHeight == nil ? .infinity : nil)
            }
            if let r = store.justRetracted, !store.isBrowsing {
                // bewust klein en grijs: wat niet meer klopt hoort niet de aandacht te trekken
                Text("Retracted (\(r.reason)): \(r.text)")
                    .font(.caption).strikethrough().foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    /// Terugbladeren door de hints van deze meeting; nieuwe hints komen binnen zonder je plek te verliezen.
    private var historyBar: some View {
        let history = store.history
        let index = store.shownIndex ?? max(history.count - 1, 0)
        return HStack(spacing: 6) {
            Button { store.back() } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0 && store.isBrowsing)
                .help("Previous hint (⌘[)")
            Text("Hint \(min(index + 1, history.count)) of \(history.count)"
                 + (store.shown.map { " · " + Self.clock.string(from: $0.updated) } ?? ""))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button { store.forward() } label: { Image(systemName: "chevron.right") }
                .disabled(!store.isBrowsing)
                .help("Next hint (⌘])")
            Spacer()
            if store.isBrowsing {
                let newer = history.count - 1 - index
                Button(newer > 0 ? "Latest (\(newer) newer)" : "Latest") { store.latest() }
                    .controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Geen hint in beeld: wat de pijplijn doet, of knoppen om te beginnen.
    @ViewBuilder private var idle: some View {
        switch backend.state {
        case .running:
            Text(store.connected ? (store.status.isEmpty ? "Listening…" : store.status) : "Starting pipeline…")
                .font(.callout).foregroundStyle(.secondary)
        case .stopping:
            EmptyView()   // staat bovenaan in `stopping`, ook als er nog een hint in beeld is
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 8) {
                if case .failed(let why) = backend.state {
                    Text(why).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Knowledge base")
                    ProjectMenu(settings: settings, addFolder: addFolder).disabled(preparer.isRunning || kbPrep.isRunning)
                    if !settings.project.isEmpty && !preparer.isRunning && !kbPrep.isRunning {
                        if kbStatus.needsLoad {   // alleen als er iets te laden valt (nieuw of gewijzigd)
                            Button("Load KB") { preparer.startPrepare(settings) }
                            .help("In advance: update documents from the source folder, index the KB and load speech "
                                  + "recognition, so the meeting starts quickly")
                        }
                        Button { find() } label: { Label("Find Documents", systemImage: "magnifyingglass") }
                            .help("Find a document by its content (⌘F)")
                    }
                    Spacer()
                    Button { openSettings() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Settings")
                }
                .controlSize(.small)
                if kbPrep.state != .idle {   // een map wordt een kennisbank (kan uren duren; Stop en later verder)
                    Text(kbPrep.isRunning ? kbPrep.title : kbPrep.title.replacingOccurrences(of: "Ingesting", with: "Ingested"))
                        .font(.caption.weight(.medium))
                    TaskProgressView(task: kbPrep, tick: tick)
                }
                preparation
                HStack {
                    TextField("Meeting info (e.g. with whom, where) – used in the report name", text: $settings.meetingInfo)
                    Picker("Language", selection: $settings.language) {
                        ForEach(Settings.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden().fixedSize()
                    .help("Language of the conversation, for speech recognition; hints and the report follow it. "
                          + "Multilingual recognizes the language per utterance (less reliable for very short ones).")
                }
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                if !settings.project.isEmpty {
                    HStack {
                        Button("Start Meeting · \(settings.projectLabel)") { startMeeting() }
                            .buttonStyle(.borderedProminent)
                        Button("Play Recording…") { playRecording() }
                    }
                    .controlSize(.small)
                    .disabled(preparer.isRunning || kbPrep.isRunning)
                }
            }
        }
    }

    /// Voortgang of uitkomst van "KB laden": echte voortgang als de stap die meldt, anders een schatting
    /// uit de vorige keer, en alleen de allereerste keer een wieltje.
    private var preparation: some View { PhasedProgressView(task: preparer, tick: tick) }

    /// Tijdens het afsluiten: wat de pijplijn nog doet en hoe lang al; de stappen hebben geen vaste duur.
    private var stopping: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quitting – waiting for the report").font(.callout.weight(.medium))
                Text(stoppingStep + (backend.stoppingSince.map { " · " + elapsed(since: $0) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Abort Now") { backend.abort() }
                .controlSize(.small).help("Don't wait for the report; the transcript is already saved or will be lost")
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var stoppingStep: String {
        // tot de pijplijn iets nieuws meldt, staat er nog "Luistert…"
        store.status.isEmpty || store.status == "Listening…" ? "Processing the last utterance…" : store.status
    }

    private func seconds(_ s: Double) -> String {
        s < 90 ? "\(Int(s.rounded())) s" : "\(Int((s / 60).rounded())) min"
    }

    private func elapsed(since start: Date) -> String {
        let s = max(0, Int(tick.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if !store.project.isEmpty { Text(store.project).font(.caption).foregroundStyle(.secondary) }
            if backend.isRunning && !settings.meetingInfo.isEmpty {
                Text("· \(settings.meetingInfo)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if backend.state == .running {
                Button("Stop") { stopMeeting() }.buttonStyle(.borderless).font(.caption)
            }
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
        }
        .background(WindowDragArea())   // het paneel verslepen kan hier, aan de kopbalk
        .help("Drag to move the panel; click to show the HintMeet menu bar (top left)")
    }
}

struct HintCard: View {
    let hint: Hint
    let rate: (Int) -> Void

    /// "- punt" van het model als "• punt" tonen.
    static func bullets(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") || t.hasPrefix("* ") ? "• " + t.dropFirst(2) : String(line)
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // wat je kunt zeggen: groot, met een accentbalk ervoor zodat het in één blik te vinden is
            Text(HintCard.bullets(hint.text) + (hint.state == .streaming ? " …" : ""))
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
                Text("checking source").font(.caption).foregroundStyle(.secondary)
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

/// Scrollbaar transcript van de meeting. De uitspraak waarop de getoonde hint reageert staat in het rood;
/// uitspraken met een hint hebben een 💡 (klik om die hint te tonen). Volgt live de nieuwste uitspraak,
/// en springt bij terugbladeren naar de uitspraak van die hint.
struct TranscriptView: View {
    @ObservedObject var store: HintStore
    /// Onderaan = live: nieuwe uitspraken scrollen mee en rechts staat de nieuwste hint.
    @State private var atBottom = true
    /// Na een scroll door de app zelf (pijltjes, Latest, nieuwe uitspraak) even niet de hint laten
    /// volgen uit de scrollpositie, anders vechten die twee met elkaar.
    @State private var ignoreScrollUntil = Date.distantPast
    /// Scrollpositie bij de vorige meting: alleen als die verandert heeft er echt gescrold
    /// (een klik of een regel die hoger wordt, verandert wat er in beeld staat maar niet de positie).
    @State private var lastOffset: CGFloat?

    var body: some View {
        let focus = store.shown?.id
        let hinted = store.hinted
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.transcript) { u in
                            row(u, focused: u.id == focus, hasHint: hinted.contains(u.id))
                                .id(u.id)
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: RowFrames.self,
                                                           value: [u.id: g.frame(in: .named("transcript"))])
                                })
                                .onTapGesture { store.focus(onUtterance: u.id) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint("Shows the hint for this moment in the conversation")
                        }
                    }
                    .padding(.trailing, 6)
                    .background(GeometryReader { g in   // de hele inhoud: zijn positie is de scrollpositie
                        Color.clear.preference(key: RowFrames.self, value: [Int.min: g.frame(in: .named("transcript"))])
                    })
                }
                .coordinateSpace(name: "transcript")
                .onPreferenceChange(RowFrames.self) { frames in
                    followScroll(frames, height: viewport.size.height)
                }
                .onChange(of: store.transcript.last?.id) { _, last in
                    if atBottom && !store.isBrowsing, let last { scroll(proxy, to: last, anchor: .bottom) }
                }
                .onChange(of: focus) { _, id in   // hint gekozen door te scrollen in de hintlijst
                    guard store.selectionSource == .hints, let id else { return }
                    scroll(proxy, to: id, anchor: .center, animated: true)
                }
                .onChange(of: store.revealToken) { _, _ in   // jouw keuze: naar de uitspraak van die hint, ook de nieuwste
                    if let id = store.shown?.id { scroll(proxy, to: id, anchor: .center, animated: true) }
                }
                .onAppear { if let last = store.transcript.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: Int, anchor: UnitPoint, animated: Bool = false) {
        ignoreScrollUntil = Date().addingTimeInterval(0.5)
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: anchor) }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    /// Wat er in beeld staat bepaalt de hint: helemaal onderaan = live, anders de hint van de uitspraak
    /// met 💡 die het dichtst bij het midden staat. Staat er geen 💡 in beeld, dan blijft de hint staan.
    private func followScroll(_ all: [Int: CGRect], height: CGFloat) {
        guard !store.transcript.isEmpty else { return }
        let offset = all[Int.min]?.minY
        var frames = all
        frames[Int.min] = nil
        defer { lastOffset = offset }
        let scrolled = offset != nil && lastOffset != nil && abs(offset! - lastOffset!) > 0.5
        // onderaan = een van de laatste twee uitspraken staat in beeld; een net binnengekomen uitspraak
        // staat heel even onder de rand, en dat is geen omhoog scrollen
        let lastTwo = store.transcript.suffix(2).map(\.id)
        let bottom = lastTwo.contains { id in frames[id].map { $0.minY < height && $0.maxY > 0 } ?? false }
        if bottom != atBottom { atBottom = bottom }
        guard scrolled, Date() >= ignoreScrollUntil else { return }   // alleen jouw scrollen kiest een hint
        if bottom {
            if store.isBrowsing { store.latest(from: .transcript) }
            return
        }
        let hinted = store.hinted
        let middle = height / 2
        let visible = frames.filter { hinted.contains($0.key) && $0.value.maxY > 0 && $0.value.minY < height }
        guard let best = visible.min(by: { abs($0.value.midY - middle) < abs($1.value.midY - middle) })?.key,
              best != store.shown?.id else { return }
        // drempel: de getoonde uitspraak blijft zolang hij in beeld is en niet duidelijk verder van het midden
        // staat; anders springt de selectie heen en weer als de vette regel hoger wordt
        if let current = store.shown?.id, let now = visible[current], let next = visible[best],
           abs(now.midY - middle) - abs(next.midY - middle) < 40 { return }
        store.browse(to: best, from: .transcript)
    }

    private func row(_ u: Utterance, focused: Bool, hasHint: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(u.time).font(.caption2).monospacedDigit()
                .foregroundStyle(focused ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            // de uitspraak van de getoonde hint: vet wit op lichtrood, goed leesbaar in licht en donker
            (Text(u.speaker + ": ").fontWeight(focused ? .heavy : .semibold) + Text(u.text).fontWeight(focused ? .bold : .regular))
                .font(.callout)
                .foregroundStyle(focused ? Color.white : Color.primary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)   // geen tekstselectie: een klik selecteert de uitspraak
            Spacer(minLength: 0)
            if hasHint { Text("💡").font(.caption) }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(focused ? Color(red: 0.93, green: 0.33, blue: 0.33).opacity(0.9) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .help(hasHint ? "Click to show the hint for this utterance" : "Click to show the hint from this moment")
    }
}

/// Posities van de uitspraken in het transcript (in het assenstelsel van de scrollview).
private struct RowFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
