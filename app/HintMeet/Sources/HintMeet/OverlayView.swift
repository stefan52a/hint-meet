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
    @ObservedObject var dock: ColumnDock
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
    private var inMeeting: Bool {
        backend.isRunning || backend.state == .stopping || !store.transcript.isEmpty || store.summaryPath != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if inMeeting {
                meetingBar.padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if !store.apiErrors.isEmpty { apiErrorBanner }
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
            if state != .running && state != .stopping { meetingStarted = nil }   // ook na een fout: nieuwe klok
        }
        .onChange(of: settings.language) { _, code in   // tijdens een meeting: meteen naar de pijplijn
            if backend.isRunning { send(["type": "language", "code": code]) }
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
            if !store.apiErrors.isEmpty { apiErrorBanner }   // bv. de meeting kon niet starten zonder Jev-key
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
                TextField("With whom, where (optional; used in the report file name)", text: $settings.meetingInfo)
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
            } else if case .failed = backend.state {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Stopped with an error").font(.callout.weight(.semibold))
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ended").font(.callout.weight(.semibold))
            }
            Text([store.project.isEmpty ? settings.projectLabel : store.project, settings.meetingInfo]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if backend.isRunning && backend.state != .stopping {
                PulsingText(text: store.connected ? (store.status.isEmpty ? "Listening…" : store.status)
                                                  : "Starting pipeline…")
            }
            Spacer()
            if backend.isRunning && backend.state != .stopping {   // taal wisselen tijdens de meeting
                Picker("Language", selection: $settings.language) {
                    ForEach(Settings.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden().fixedSize()
                .help("Language of the conversation: speech recognition, hints and the report follow it from the "
                      + "next utterance. Multilingual recognizes the language per speaker.")
            }
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

    /// Een API-key werkt niet: wat de API zegt, zodat je weet waarom er geen hints, bevestigingen of verslag komen.
    private var apiErrorBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.apiErrors, id: \.self) { text in
                    Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Settings…") { openSettings() }.controlSize(.small)
                .help("Change the API keys (stored in the Keychain)")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Na afloop: het verslag openen of een nieuwe meeting voorbereiden (terug naar het startscherm).
    private var endedBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
        if case .failed(let why) = backend.state {   // ook na afloop zichtbaar, niet alleen op het startscherm
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
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
        }
        .controlSize(.regular)
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Stappen van het afsluiten, in de volgorde waarin de pijplijn ze meldt (status uit src/hint_meet/cli.py).
    private static let finishSteps = ["Processing the last utterance", "Saving the transcript",
                                      "Writing the report with action items"]

    /// Waar het afsluiten is: 0, 1 of 2 (zie finishSteps).
    private var finishIndex: Int {
        if store.status.hasPrefix("Writing report") || store.status == "Report ready" { return 2 }
        if store.status.hasPrefix("Saving transcript") { return 1 }
        return 0
    }

    /// Tijdens het afsluiten: een balk over de stappen (stap 2 van 3), en bij het verslag, dat geen vaste duur
    /// heeft, daaronder een bewegende balk. Abort stopt zonder verslag (het transcript is dan al bewaard).
    private var stopping: some View {
        let steps = Self.finishSteps
        let index = finishIndex
        let writing = index == 2
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: writing ? "doc.text" : "hourglass").foregroundStyle(Color.accentColor)
                Text("Step \(index + 1) of \(steps.count): \(steps[index])…").font(.callout.weight(.medium))
                Text(backend.stoppingSince.map { elapsed(since: $0) } ?? "")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(role: .destructive) { backend.abort() } label: { Label("Abort", systemImage: "xmark") }
                    .controlSize(.small)
                    .help(writing ? "Stop without a report; the transcript is already saved in logs/"
                                  : "Stop now; the transcript is saved first if the pipeline gets that far")
            }
            ProgressView(value: Double(index), total: Double(steps.count))   // de stappen: bepaald
            if writing {
                ProgressView().progressViewStyle(.linear)   // het verslag: duur onbekend, bewegende balk
            }
            HStack(spacing: 12) {   // de stappen zelf, met ✓ voor wat klaar is
                ForEach(Array(steps.enumerated()), id: \.offset) { n, name in
                    Label(name, systemImage: n < index ? "checkmark.circle.fill" : n == index ? "circle.dotted" : "circle")
                        .font(.caption)
                        .foregroundStyle(n < index ? AnyShapeStyle(Color.green) : n == index ? AnyShapeStyle(.primary)
                                         : AnyShapeStyle(.tertiary))
                }
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var stoppingStep: String {
        // tot de pijplijn iets nieuws meldt, staat er nog "Luistert…"
        store.status.isEmpty || store.status == "Listening…" ? "Processing the last utterance…" : store.status
    }

    private func elapsed(since start: Date) -> String {
        let s = max(0, Int(tick.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Vanaf deze breedte staan de kolommen naast elkaar; smaller onder elkaar.
    static let twoColumnWidth: CGFloat = 560

    /// De kolommen die niet in een eigen venster staan, met versleepbare scheidingen ertussen.
    @ViewBuilder private var columns: some View {
        let shown = MeetingColumn.allCases.filter { !dock.undocked.contains($0) }
        if shown.isEmpty {
            VStack(spacing: 8) {
                Text("All columns are in their own windows.").font(.callout).foregroundStyle(.secondary)
                Button("Put Them Back in the Panel") { dock.dockAll() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if size.width >= Self.twoColumnWidth {
            let total = shown.map(\.share).reduce(0, +)
            HSplitView {
                ForEach(shown) { c in
                    column(c)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 200, idealWidth: size.width * c.share / total, maxWidth: .infinity,
                               maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            VSplitView {
                ForEach(shown) { c in column(c).padding(.vertical, 6).frame(minHeight: 120, maxHeight: .infinity) }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func column(_ c: MeetingColumn) -> some View {
        MeetingColumnView(column: c, store: store, settings: settings, dock: dock, send: send)
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

/// Status in de kopbalk ("Listening…"): knippert zacht, zodat je ziet dat HintMeet meeluistert. De helderheid volgt de
/// klok (geen herhalende animatie: die liet de tekst ook heen en weer schuiven).
struct PulsingText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .opacity(0.65 + 0.35 * cos(t * 2 * .pi / 2.4))   // tussen 0,3 en 1, elke 2,4 s
        }
    }
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
    /// Scrollbalk helemaal onderaan: nieuwe of groeiende uitspraken scrollen mee (ook als je een hint bekijkt).
    @State private var pinned = true
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
                                confirmed: confirmed.contains(u.id), backed: u.id == store.backedID)
                                .id(u.id)
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: RowFrames.self,
                                                           value: [u.id: g.frame(in: .named("transcript"))])
                                })
                                .onTapGesture { store.clearBacked(); store.focus(onUtterance: u.id) }
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
                .onChange(of: store.transcript.last) { _, last in   // nieuwe uitspraak, of de laatste werd langer
                    if pinned, let last { scroll(proxy, to: last.id, anchor: .bottom) }
                }
                .onChange(of: focus) { _, id in   // hint gekozen door te scrollen in de hintlijst
                    guard store.selectionSource == .hints, let id else { return }
                    scroll(proxy, to: id, anchor: .center, animated: true)
                }
                .onChange(of: store.revealToken) { _, _ in   // jouw keuze: naar de uitspraak van die hint, ook de nieuwste
                    if let id = store.shown?.id { scroll(proxy, to: id, anchor: .center, animated: true) }
                }
                .onChange(of: store.backedToken) { _, _ in   // kaart links gekozen: naar zijn uitspraak
                    if !store.backedFromTranscript, let id = store.backedID {
                        scroll(proxy, to: id, anchor: .center, animated: true)
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
    private func followScroll(_ all: [Int: CGRect], height: CGFloat) {
        // vóór een wijziging gemeten: stond de scrollbalk onderaan, dan blijft hij daar
        if let content = all[Int.min] {
            let now = content.maxY <= height + 8
            if now != pinned { pinned = now }
        }
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

    private func row(_ u: Utterance, focused hintFocused: Bool, hasHint: Bool, confirmed: Bool, backed: Bool) -> some View {
        let focused = hintFocused || backed   // gekozen via ✓ of links: groen in plaats van rood
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectBacked(u.id, fromTranscript: true) }   // gaat voor de klik op de regel
                    .help("Backed by the knowledge base: click to show it in the left column")
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(backed ? Color(red: 0.2, green: 0.62, blue: 0.32).opacity(0.9)
                        : hintFocused ? Color(red: 0.93, green: 0.33, blue: 0.33).opacity(0.9) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .contextMenu {   // rechtsklik: "Speaker 1" een echte naam geven ("Unknown" is geen persoon: alle korte reacties)
            if u.speaker != "Unknown" {
                Button("Rename \(u.speaker)…") { store.onRenameRequest?(u.speaker) }
            }
        }
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
