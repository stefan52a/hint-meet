import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var store: HintStore
    @ObservedObject var backend: Backend
    @ObservedObject var preparer: ProgressTask
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
            if backend.state == .stopping { stopping }
            if store.transcript.isEmpty && store.listHints.isEmpty {
                hintColumn(height: transcriptHeight)
            } else if layout.width >= Self.twoColumnWidth {
                // links het gesprek, rechts de hints op volgorde; de uitspraak van de hint in het midden is gemarkeerd
                HStack(alignment: .top, spacing: 12) {
                    TranscriptView(store: store).frame(width: layout.width * 0.45, height: transcriptHeight)
                    Divider().frame(height: transcriptHeight)
                    hintColumn(height: transcriptHeight).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                hintColumn(height: 240)
                Divider()
                TranscriptView(store: store).frame(height: min(transcriptHeight, 180))
            }
            if let path = store.summaryPath {
                Button("Open Report with Action Items") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .frame(width: layout.width, alignment: .topLeading)
        .frame(minHeight: layout.minHeight, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) { ResizeGrip(layout: layout).frame(width: 18, height: 18).padding(3) }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onReceive(timer) { tick = $0 }   // laat het regeltje over een ingetrokken hint na een paar seconden verdwijnen
    }

    /// Vanaf deze breedte staan transcript en hint naast elkaar; smaller komt het transcript eronder.
    static let twoColumnWidth: CGFloat = 560

    /// Hoogte van het transcript: groeit mee als je het paneel met de greep hoger maakt.
    private var transcriptHeight: CGFloat { max(240, layout.minHeight - 70) }

    /// Rechterkolom: bladeren en de hints op volgorde (of de knoppen om te beginnen), en intrekkingen.
    @ViewBuilder private func hintColumn(height: CGFloat) -> some View {
        let bar = store.history.count > 1 || store.isBrowsing
        let retracted = store.justRetracted != nil && !store.isBrowsing
        VStack(alignment: .leading, spacing: 8) {
            if store.listHints.isEmpty {
                idle
            } else {
                if bar { historyBar }
                HintsList(store: store, rate: { id, r in
                    store.rate(id, r)
                    send(["type": "feedback", "id": id, "rating": r, "session": store.session])
                })
                .frame(height: max(160, height - (bar ? 34 : 0) - (retracted ? 22 : 0)))
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
                    ProjectMenu(settings: settings).disabled(preparer.isRunning)
                    if !settings.project.isEmpty && !preparer.isRunning {
                        Button("Load KB") { preparer.startPrepare(settings) }
                            .help("In advance: update documents from the source folder, index the KB and load speech "
                                  + "recognition, so the meeting starts quickly")
                    }
                }
                .controlSize(.small)
                preparation
                TextField("Meeting info (e.g. with whom, where) – used in the report name", text: $settings.meetingInfo)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                if !settings.project.isEmpty {
                    HStack {
                        Button("Start Meeting · \(settings.projectLabel)") { startMeeting() }
                            .buttonStyle(.borderedProminent)
                        Button("Play Recording…") { playRecording() }
                    }
                    .controlSize(.small)
                    .disabled(preparer.isRunning)
                }
            }
        }
    }

    /// Voortgang of uitkomst van "KB laden": echte voortgang als de stap die meldt, anders een schatting
    /// uit de vorige keer, en alleen de allereerste keer een wieltje.
    private var preparation: some View { TaskProgressView(task: preparer, tick: tick) }

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
            Circle().fill(backend.state == .running ? (store.connected ? Color.green : Color.orange) : Color.gray)
                .frame(width: 7, height: 7)
            Text("hint-meet").font(.caption.weight(.semibold))
            if !store.project.isEmpty { Text("· \(store.project)").font(.caption).foregroundStyle(.secondary) }
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
        .help("Click here to show the HintMeet menu bar (top left)")
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

/// Greep rechtsonder om het paneel groter of kleiner te slepen. Een randloos paneel dat geen focus
/// mag krijgen heeft geen sleepranden van macOS, en slepen op de achtergrond verplaatst het paneel.
struct ResizeGrip: NSViewRepresentable {
    let layout: PanelLayout

    func makeNSView(context: Context) -> GripView { GripView(layout: layout) }
    func updateNSView(_ view: GripView, context: Context) {}

    final class GripView: NSView {
        let layout: PanelLayout
        private var start: (mouse: NSPoint, width: CGFloat, height: CGFloat)?

        init(layout: PanelLayout) {
            self.layout = layout
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override var mouseDownCanMoveWindow: Bool { false }   // anders sleept het hele paneel mee
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.tertiaryLabelColor.setStroke()
            let path = NSBezierPath()
            for i in 1...3 {   // drie schuine streepjes, zoals een klassieke venstergreep
                let d = CGFloat(i) * 4
                path.move(to: NSPoint(x: bounds.maxX - d - 2, y: 2))
                path.line(to: NSPoint(x: bounds.maxX - 2, y: d + 2))
            }
            path.lineWidth = 1
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            start = (NSEvent.mouseLocation, window.frame.width, window.frame.height)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let now = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                layout.width = max(start.width + now.x - start.mouse.x, PanelLayout.minWidth)
                layout.minHeight = max(start.height - (now.y - start.mouse.y), 0)   // schermcoördinaten: y omhoog
            }
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
            MainActor.assumeIsolated {
                layout.clamp(to: window?.screen?.visibleFrame.size)
                layout.save()
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
                                .onTapGesture { store.browse(to: u.id, from: .other) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(hinted.contains(u.id) ? .isButton : [])
                                .accessibilityHint(hinted.contains(u.id) ? "Shows the hint for this utterance" : "")
                        }
                    }
                    .padding(.trailing, 6)
                }
                .coordinateSpace(name: "transcript")
                .onPreferenceChange(RowFrames.self) { frames in
                    followScroll(frames, height: viewport.size.height)
                }
                .onChange(of: store.transcript.last?.id) { _, last in
                    if atBottom && !store.isBrowsing, let last { scroll(proxy, to: last, anchor: .bottom) }
                }
                .onChange(of: focus) { _, id in
                    if store.selectionSource == .transcript { return }   // door jouw scrollen hier gekozen: niet verspringen
                    guard let id, store.isBrowsing else { return }
                    scroll(proxy, to: id, anchor: .center, animated: true)
                }
                .onChange(of: store.isBrowsing) { _, browsing in   // terug naar Latest: weer live meelezen
                    if !browsing, store.selectionSource != .transcript, let last = store.transcript.last?.id {
                        scroll(proxy, to: last, anchor: .bottom)
                    }
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
    private func followScroll(_ frames: [Int: CGRect], height: CGFloat) {
        guard let lastID = store.transcript.last?.id else { return }
        let bottom = frames[lastID].map { $0.maxY <= height + 8 } ?? false
        if bottom != atBottom { atBottom = bottom }
        guard Date() >= ignoreScrollUntil else { return }
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
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if hasHint { Text("💡").font(.caption).help("Show the hint for this utterance") }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(focused ? Color(red: 0.93, green: 0.33, blue: 0.33).opacity(0.9) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }
}

/// Posities van de uitspraken in het transcript (in het assenstelsel van de scrollview).
private struct RowFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
