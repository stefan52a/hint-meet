import AppKit
import SwiftUI

/// Zoekdienst voor "Find Document": houdt `hint-meet search --serve` open zolang het venster open is, zodat de
/// kennisbank één keer laadt en elke zoekvraag daarna direct antwoord geeft.
@MainActor
final class SearchService: ObservableObject {
    struct Result: Identifiable, Equatable {
        let ref: String, heading: String, snippet: String, path: String
        /// Jev-relevantie (0…1), als de reranker meedeed; injection: lijkt instructies aan een AI te bevatten.
        var relevance: Double? = nil
        var injection = false
        var id: String { ref }
        var name: String { (ref as NSString).lastPathComponent }

        init(_ d: [String: Any]) {
            ref = d["ref"] as? String ?? ""; heading = d["heading"] as? String ?? ""
            snippet = d["snippet"] as? String ?? ""; path = d["path"] as? String ?? ""
            relevance = d["relevance"] as? Double; injection = d["injection"] as? Bool ?? false
        }
    }
    /// meeting: tijdens een meeting zoeken in de KB die de meeting al geladen heeft (geen tweede kopie)
    enum State: Equatable { case idle, loading, ready(Int), meeting, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var results: [Result] = []
    @Published private(set) var lastQuery = ""
    @Published private(set) var searching = false
    /// Heeft Jev de resultaten beoordeeld? Dan betekent een lege lijst "niets relevants", niet "niets gevonden".
    @Published private(set) var reranked = false
    /// Zoekvraag die gesteld wordt zodra de kennisbank geladen is (voor tests: HINT_MEET_FIND).
    var pendingQuery: String?
    /// Loopt er een meeting? Dan via de meeting-pijplijn zoeken in plaats van een eigen zoekproces.
    var meetingActive: () -> Bool = { false }
    var sendToMeeting: ([String: Any]) -> Void = { _ in }
    /// Melding bij zoeken via de meeting, bv. dat die de kennisbank nog aan het laden is.
    @Published private(set) var meetingNote = ""
    let loading = ProgressTask(logName: "search")   // alleen voor de fasen tijdens het laden
    private var process: Process?
    private var input: FileHandle?
    /// Elke start van het zoekproces krijgt een nieuwe generatie; regels van een vorig proces tellen niet mee.
    private var generation = 0
    /// Volgnummer van de laatst gestelde vraag: alleen het antwoord daarop wordt getoond.
    private var lastRequest = 0
    private var projects = ""
    private let settings: Settings

    init(settings: Settings) { self.settings = settings }

    /// Start (of herstart, als de gekozen projecten veranderd zijn) de zoekdienst.
    func ensureRunning() {
        if meetingActive() {   // de meeting heeft de KB al geladen: daarin zoeken, niets extra laden
            if state != .meeting { stop(); state = .meeting }
            return
        }
        if process?.isRunning == true && projects == settings.project { return }
        stop()
        guard settings.backendReady, !settings.project.isEmpty else {
            state = .failed(settings.project.isEmpty ? "Choose a knowledge base first" : "No Python environment")
            return
        }
        projects = settings.project
        let p = Backend.pythonProcess(settings, ["-m", "hint_meet.cli", "--project", settings.project, "search", "--serve"])
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inp
        generation += 1
        let gen = generation
        let lines = LineSplitter()
        let queue = DispatchQueue(label: "hintmeet.search")
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            queue.async {
                let complete = lines.feed(data, atEnd: false)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == gen else { return }   // regels van een vorig proces
                        complete.forEach { self.read($0) }
                    }
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === proc else { return }
                    self.process = nil
                    if case .loading = self.state { self.state = .failed("Loading the knowledge base failed") }
                }
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
            state = .loading
            loading.begin(title: "Loading \(settings.projectLabel)")
        } catch {
            state = .failed("Could not start: \(error.localizedDescription)")
        }
    }

    /// Draait de zoekdienst (geladen of bezig met laden)?
    var isLoaded: Bool { process?.isRunning == true }

    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !q.isEmpty else { return }
        if meetingActive() {
            if state != .meeting { stop(); state = .meeting }
            searching = true
            lastQuery = q
            lastRequest += 1
            meetingNote = ""
            sendToMeeting(["type": "search", "id": lastRequest, "query": q])
            let request = lastRequest
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in   // geen antwoord (meeting voorbij,
                guard let self, self.searching, self.lastRequest == request else { return }   // verbinding weg)
                self.searching = false
                self.meetingNote = "No answer from the meeting. Search again; if the meeting has ended, HintMeet loads the knowledge base itself."
                if !self.meetingActive() { self.state = .idle }
            }
            return
        }
        if state == .meeting { state = .idle }   // meeting voorbij: weer met een eigen zoekproces
        if projects != settings.project {   // ander project gekozen: eerst die kennisbank laden, dan zoeken
            pendingQuery = q
            ensureRunning()
            return
        }
        guard let input, case .ready = state else {
            pendingQuery = q   // nog aan het laden: vraag bewaren en stellen zodra de kennisbank klaar is
            if process == nil { ensureRunning() }
            return
        }
        searching = true
        lastQuery = q
        lastRequest += 1
        input.write(Data("\(lastRequest)\t\(q.replacingOccurrences(of: "\t", with: " "))\n".utf8))
    }

    /// Antwoord van de meeting-pijplijn op een zoekvraag.
    func receiveMeetingResults(_ msg: [String: Any]) {
        guard (msg["id"] as? Int) == lastRequest else { return }   // antwoord op een eerdere vraag
        searching = false
        if msg["error"] as? String == "loading" {
            results = []
            meetingNote = "The meeting is still loading the knowledge base; try again in a moment."
            return
        }
        results = (msg["results"] as? [[String: Any]] ?? []).map(Result.init)
        reranked = msg["reranked"] as? Bool ?? false
    }

    func stop() {
        generation += 1   // wat het oude proces nog stuurt, wordt genegeerd
        input = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        state = .idle
    }

    private func read(_ line: String) {
        if line.hasPrefix("@ready ") {
            state = .ready(Int(line.dropFirst(7)) ?? 0)
            loading.end()
            if let q = pendingQuery { pendingQuery = nil; search(q) }
        } else if line.hasPrefix("@results "), let data = line.dropFirst(9).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["results"] as? [[String: Any]] {
            guard json["id"] as? String == String(lastRequest) else { return }   // antwoord op een eerdere vraag
            results = list.map(Result.init)
            reranked = json["reranked"] as? Bool ?? false
            searching = false
        } else if line.hasPrefix("@") {
            loading.feed(line)   // @plan / @step / @progress: voortgang van het laden
        }
    }
}

/// Venster "Find Document": zoek een document op inhoud in de gekozen kennisbank(en).
struct FindView: View {
    @ObservedObject var search: SearchService
    @ObservedObject var settings: Settings
    @State private var query = ""
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("What are you looking for? Words, an amount, a name, a topic…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search.search(query) }
                Button("Find") { search.search(query) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || !isReady)
            }
            Text("In: \(settings.projectLabel.isEmpty ? "—" : settings.projectLabel)")
                .font(.caption).foregroundStyle(.secondary)
            switch search.state {
            case .idle:
                EmptyView()
            case .loading:
                PhasedProgressView(task: search.loading, tick: tick)
            case .failed(let why):
                Text(why).font(.callout).foregroundStyle(.orange)
            case .ready(let chunks):
                resultList(empty: "Ready: \(chunks) passages searchable.")
            case .meeting:
                if !search.meetingNote.isEmpty {
                    Text(search.meetingNote).font(.callout).foregroundStyle(.orange)
                }
                resultList(empty: "Searching the knowledge base of the running meeting.")
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 520, minHeight: 360)
        .onReceive(timer) { tick = $0 }
        .onAppear { search.ensureRunning() }
    }

    private var isReady: Bool {
        switch search.state {
        case .ready, .meeting: return true
        default: return false
        }
    }

    @ViewBuilder private func resultList(empty: String) -> some View {
        if search.results.isEmpty {
            Text(search.lastQuery.isEmpty ? empty
                 : search.searching ? "Searching…"
                 : search.reranked ? "Nothing relevant found for “\(search.lastQuery)”."
                 : "Nothing found for “\(search.lastQuery)”.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("\(search.results.count) \(search.reranked ? "relevant " : "")documents for “\(search.lastQuery)”, best match first")
                .font(.caption).foregroundStyle(.secondary)
            List(search.results) { r in row(r) }
                .listStyle(.inset)
        }
    }

    private func row(_ r: SearchService.Result) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(r.name).font(.headline).lineLimit(1)
                if let rel = r.relevance {
                    Text("\(Int((rel * 100).rounded()))% relevant").font(.caption).foregroundStyle(.secondary)
                        .help("How well this passage answers your search, judged by Jev")
                }
                Spacer()
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: r.path)) }
                    .buttonStyle(.link)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
                    .buttonStyle(.link)
            }
            Text(r.ref).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if !r.heading.isEmpty {
                Text(r.heading).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
            }
            Text(r.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            if r.injection {
                Label("This passage seems to contain instructions to an AI; HintMeet doesn't use it for hints.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
