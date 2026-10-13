import AppKit
import SwiftUI

/// Het paneel. Twee standen:
/// - start: één kaart met drie stappen (kennisbank, meeting, starten);
/// - meeting (ook na afloop, tot "New Meeting"): een kopbalk en drie kolommen met dezelfde kop:
///   onderbouwd door de KB | transcript | hints en correcties.
/// Onderaan altijd een smalle balk met Restart.
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
    let restart: () -> Void
    @State private var tick = Date()
    /// Net een verslag klaar: een knipperende pijl wijst er 5 seconden naar.
    @State private var pointAtReport = false
    @State private var blink = false
    /// Begin van de lopende meeting, voor de klok in de kopbalk.
    @State private var meetingStarted: Date?
    @State private var size = CGSize(width: PanelLayout.defaultWidth, height: 560)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Meetingstand: tijdens een meeting, en daarna zolang het gesprek nog in beeld is.
    private var inMeeting: Bool { backend.isRunning || backend.state == .stopping || !store.transcript.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if inMeeting {
                meetingBar.padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if backend.state == .stopping { stopping }
                    if !backend.isRunning && backend.state != .stopping { endedBanner }
                    columns
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView { setupCard.padding(.vertical, 28).padding(.horizontal, 16) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer.padding(.horizontal, 14).padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // vult het venster
        .background(.regularMaterial)
        .background(GeometryReader { g in   // breedte en hoogte van het venster, voor de indeling
            Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s }
        })
        .onReceive(timer) { tick = $0 }   // klok, voortgang, en het regeltje over een ingetrokken hint
        .onChange(of: backend.state) { _, state in
            if state == .running && meetingStarted == nil { meetingStarted = Date() }
            if state == .idle { meetingStarted = nil }
        }
        .onChange(of: store.summaryPath) { _, path in
            guard path != nil else { pointAtReport = false; return }
            pointAtReport = true
            blink = false
            DispatchQueue.main.async { blink = true }   // na de eerste weergave: dan start het knipperen
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { pointAtReport = false; blink = false }
        }
    }

    // MARK: startscherm

    private var kbBusy: Bool { preparer.isRunning || kbPrep.isRunning }

    /// Drie stappen in één kaart, gecentreerd: kennisbank kiezen (en laden), meeting beschrijven, starten.
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            if case .failed(let why) = backend.state {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            step(1, "Knowledge base") {
                HStack(spacing: 10) {
                    ProjectMenu(settings: settings, addFolder: addFolder).disabled(kbBusy)
                    kbBadge
                    Spacer()
                    if !settings.project.isEmpty && !kbBusy && kbStatus.needsLoad {
                        Button("Preload KB") { preparer.startPrepare(settings) }
                            .help("In advance: update documents from the source folder, index the KB and load speech "
                                  + "recognition, so the meeting starts quickly")
                    }
                }
                if kbStatus.needsLoad && !settings.project.isEmpty && !kbBusy {
                    Text("Preload well before a meeting: the first time, embedding the documents can take hours "
                         + "(days for very large folders). You can stop and continue later.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if kbPrep.state != .idle {   // een map wordt een kennisbank (kan uren duren; Stop en later verder)
                    Text(kbPrep.isRunning ? kbPrep.title : kbPrep.title.replacingOccurrences(of: "Ingesting", with: "Ingested"))
                        .font(.caption.weight(.medium))
                    TaskProgressView(task: kbPrep, tick: tick)
                }
                PhasedProgressView(task: preparer, tick: tick, collapsible: true)
            }
            step(2, "Meeting") {
                TextField("With whom, where (optional; used in the report name)", text: $settings.meetingInfo)
                    .textFieldStyle(.roundedBorder)
                Picker("Language", selection: $settings.language) {
                    ForEach(Settings.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .fixedSize()
                .help("Language of the conversation, for speech recognition; hints and the report follow it. "
                      + "Multilingual recognizes the language per utterance (less reliable for very short ones).")
            }
            step(3, "Start") {
                Button { startMeeting() } label: {
                    Label("Start Meeting", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledButtonStyle(color: .accentColor, large: true))
                .disabled(settings.project.isEmpty || kbBusy)
                .help(settings.project.isEmpty ? "Choose a knowledge base first" : "Listen along with \(settings.projectLabel)")
                Button("Use a recorded meeting instead…") { playRecording() }
                    .buttonStyle(.link).font(.caption)
                    .disabled(settings.project.isEmpty || kbBusy)
            }
        }
        .padding(24)
        .frame(maxWidth: 600, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .frame(maxWidth: .infinity)   // gecentreerd in het venster
    }

    /// Eén genummerde stap van het startscherm.
    private func step<Content: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.callout.weight(.bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    /// Stand van de gekozen kennisbank in één woord.
    @ViewBuilder private var kbBadge: some View {
        if settings.project.isEmpty {
            EmptyView()
        } else if kbBusy {
            Label("Loading…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                .font(.caption)
        } else if kbStatus.needsLoad {
            Label("Not loaded", systemImage: "circle.dashed").foregroundStyle(.orange).font(.caption)
        } else {
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        }
    }

    // MARK: meeting

    /// Kopbalk: opname en tijd, met wie, wat de pijplijn doet, zoeken en stoppen. Hier versleep je het paneel.
    private var meetingBar: some View {
        HStack(spacing: 10) {
            if backend.isRunning && backend.state != .stopping {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                    .opacity(Int(tick.timeIntervalSince1970) % 2 == 0 ? 1 : 0.35)
                Text("REC " + (meetingStarted.map { TaskProgressView.elapsed(from: $0, to: tick) } ?? ""))
                    .font(.callout.weight(.semibold)).monospacedDigit()
            } else if backend.state == .stopping {
                ProgressView().controlSize(.small)
                Text("Finishing").font(.callout.weight(.semibold))
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ended").font(.callout.weight(.semibold))
            }
            Text([store.project.isEmpty ? settings.projectLabel : store.project, settings.meetingInfo]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if backend.isRunning && backend.state != .stopping {
                Text(store.connected ? (store.status.isEmpty ? "Listening…" : store.status) : "Starting pipeline…")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Button { find() } label: { Label("Find", systemImage: "magnifyingglass") }
                .help("Find a document by its content in the knowledge base (⌘F)")
            if backend.isRunning && backend.state != .stopping {
                Button { stopMeeting() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(FilledButtonStyle(color: .red))
                    .help("Stop listening and write the report")
            }
        }
        .controlSize(.small)
        .background(WindowDragArea())   // het paneel verslepen kan hier, aan de kopbalk
        .help("Drag to move the panel; click to show the HintMeet menu bar (top left)")
    }

    /// Na afloop: het verslag openen of een nieuwe meeting voorbereiden (terug naar het startscherm).
    private var endedBanner: some View {
        HStack(spacing: 10) {
            if let path = store.summaryPath {
                if pointAtReport {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color.accentColor)
                        .opacity(blink ? 1 : 0.15)
                        .animation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true), value: blink)
                        .accessibilityHidden(true)
                }
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                    Label("Open Report with Action Items", systemImage: "doc.text")
                }
                .buttonStyle(FilledButtonStyle(color: .accentColor))
            } else {
                Text("Meeting ended. No report was written.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.clearMeeting() } label: { Label("New Meeting", systemImage: "plus") }
                .help("Back to the start screen; the report stays in the meetings folder")
        }
        .controlSize(.regular)
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

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

    private func elapsed(since start: Date) -> String {
        let s = max(0, Int(tick.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Vanaf deze breedte staan transcript en hint naast elkaar; smaller komt alles onder elkaar.
    static let twoColumnWidth: CGFloat = 560
    /// Vanaf deze breedte krijgt wat de KB onderbouwt een eigen kolom links.
    static let threeColumnWidth: CGFloat = 860

    /// De drie kolommen; smaller schuiven ze in elkaar. Transcript en hints krijgen alle overgebleven hoogte.
    @ViewBuilder private var columns: some View {
        if size.width >= Self.threeColumnWidth {
            HStack(alignment: .top, spacing: 12) {
                backedColumn.frame(width: size.width * 0.27)
                Divider()
                transcriptColumn.frame(width: size.width * 0.34)
                Divider()
                hintColumn
            }
            .frame(maxHeight: .infinity)
        } else if size.width >= Self.twoColumnWidth {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    transcriptColumn
                    Divider()
                    backedColumn.frame(height: store.confirmations.isEmpty ? nil : size.height * 0.3)
                }
                .frame(width: size.width * 0.45)
                Divider()
                hintColumn
            }
            .frame(maxHeight: .infinity)
        } else {
            hintColumn.frame(height: 220)
            Divider()
            transcriptColumn
            Divider()
            backedColumn.frame(height: store.confirmations.isEmpty ? nil : 140)
        }
    }

    /// Dezelfde kop boven elke kolom: icoon, titel, aantal, en eventueel het gevoeligheidsschuifje.
    private func columnHeader(_ title: String, icon: String, count: Int, slider: Binding<Double>? = nil,
                              sliderHelp: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                if count > 0 {
                    Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer(minLength: 0)
            }
            if let slider {
                SensitivitySlider(title: "", value: slider, help: sliderHelp, changed: sendSensitivity)
            }
        }
    }

    private var backedColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnHeader("Backed by the KB", icon: "checkmark.seal", count: store.confirmations.count,
                         slider: $settings.confirmSensitivity,
                         sliderHelp: "More: also less clearly matching passages and shorter utterances. Fewer: only "
                             + "clear matches. A ✓ always means nothing in the utterance contradicts the documents.")
            ConfirmList(store: store)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnHeader("Transcript", icon: "text.bubble", count: store.transcript.count)
            if store.transcript.isEmpty {
                placeholder("What is said appears here.")
            } else {
                TranscriptView(store: store)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Rechterkolom: bladeren en de hints op volgorde, en intrekkingen.
    private var hintColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnHeader("Hints & corrections", icon: "lightbulb", count: store.history.count,
                         slider: $settings.hintSensitivity,
                         sliderHelp: "More: hints and corrections also when the gatekeeper is less sure and on less "
                             + "clearly matching passages. Fewer: only when it clearly matters.")
            if store.listHints.isEmpty {
                placeholder("Answers and corrections from your documents appear here when they matter.")
            } else {
                if store.history.count > 1 || store.isBrowsing { historyBar }
                HintsList(store: store, rate: { id, r in
                    store.rate(id, r)
                    send(["type": "feedback", "id": id, "rating": r, "session": store.session])
                })
                .frame(maxHeight: .infinity)
            }
            if let r = store.justRetracted, !store.isBrowsing {
                // bewust klein en grijs: wat niet meer klopt hoort niet de aandacht te trekken
                Text("Retracted (\(r.reason)): \(r.text)")
                    .font(.caption).strikethrough().foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    // MARK: onderbalk

    /// Altijd: zoeken en instellingen (buiten een meeting) en Restart.
    private var footer: some View {
        HStack(spacing: 14) {
            if !inMeeting {
                Button { find() } label: { Label("Find Documents", systemImage: "magnifyingglass") }
                    .disabled(settings.project.isEmpty)
                    .help("Find a document by its content (⌘F)")
            }
            Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
            Spacer()
            Button { restart() } label: { Label("Restart HintMeet", systemImage: "arrow.clockwise") }
                .help("Quits HintMeet and starts the latest build (⌘R); a running meeting finishes its report first")
        }
        .buttonStyle(.borderless).font(.caption).controlSize(.small)
    }

    /// Schuifjes naar de lopende meeting; geldt vanaf de volgende uitspraak.
    private func sendSensitivity() { send(settings.sensitivityMessage) }
}

/// Gevulde knop in een vaste kleur. .borderedProminent wordt grijs in een venster dat niet actief is, en dit
/// paneel wordt bewust nooit actief (het neemt je toetsenbord niet over): dan vallen Start en Stop weg.
struct FilledButtonStyle: ButtonStyle {
    let color: Color
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .body.weight(.semibold) : .callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 16 : 10).padding(.vertical, large ? 8 : 3)
            .background(RoundedRectangle(cornerRadius: large ? 8 : 6)
                .fill(color.opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.75 : 1)))
            .contentShape(Rectangle())
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
        let confirmed = Set(store.confirmations.filter(\.confirms).map(\.id))   // 📄-regels krijgen geen ✓
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.transcript) { u in
                            row(u, focused: u.id == focus, hasHint: hinted.contains(u.id),
                                confirmed: confirmed.contains(u.id))
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

    private func row(_ u: Utterance, focused: Bool, hasHint: Bool, confirmed: Bool) -> some View {
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
            if confirmed {
                Image(systemName: "checkmark.circle.fill").font(.caption)
                    .foregroundStyle(focused ? Color.white : Color.green)
                    .help("Backed by the knowledge base (left column)")
            }
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
