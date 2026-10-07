import AppKit
import SwiftUI

/// Zoekdienst voor "Find Document": houdt `hint-meet search --serve` open zolang het venster open is, zodat de
/// kennisbank één keer laadt en elke zoekvraag daarna direct antwoord geeft.
@MainActor
final class SearchService: ObservableObject {
    struct Result: Identifiable, Equatable {
        let ref: String, heading: String, snippet: String, path: String
        var id: String { ref }
        var name: String { (ref as NSString).lastPathComponent }
    }
    enum State: Equatable { case idle, loading, ready(Int), failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var results: [Result] = []
    @Published private(set) var lastQuery = ""
    @Published private(set) var searching = false
    /// Zoekvraag die gesteld wordt zodra de kennisbank geladen is (voor tests: HINT_MEET_FIND).
    var pendingQuery: String?
    let loading = ProgressTask(logName: "search")   // alleen voor de fasen tijdens het laden
    private var process: Process?
    private var input: FileHandle?
    private var projects = ""
    private let settings: Settings

    init(settings: Settings) { self.settings = settings }

    /// Start (of herstart, als de gekozen projecten veranderd zijn) de zoekdienst.
    func ensureRunning() {
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
        let lines = LineSplitter()
        let queue = DispatchQueue(label: "hintmeet.search")
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            queue.async {
                let complete = lines.feed(data, atEnd: false)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { complete.forEach { self?.read($0) } }
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

    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !q.isEmpty, let input, case .ready = state else { return }
        searching = true
        lastQuery = q
        input.write(Data((q + "\n").utf8))
    }

    func stop() {
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
            results = list.map { Result(ref: $0["ref"] as? String ?? "", heading: $0["heading"] as? String ?? "",
                                        snippet: $0["snippet"] as? String ?? "", path: $0["path"] as? String ?? "") }
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
                if search.results.isEmpty {
                    Text(search.lastQuery.isEmpty ? "Ready: \(chunks) passages searchable."
                         : search.searching ? "Searching…" : "Nothing found for “\(search.lastQuery)”.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("\(search.results.count) documents for “\(search.lastQuery)”, best match first")
                        .font(.caption).foregroundStyle(.secondary)
                    List(search.results) { r in row(r) }
                        .listStyle(.inset)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 520, minHeight: 360)
        .onReceive(timer) { tick = $0 }
        .onAppear { search.ensureRunning() }
    }

    private var isReady: Bool { if case .ready = search.state { return true }; return false }

    private func row(_ r: SearchService.Result) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(r.name).font(.headline).lineLimit(1)
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
        }
        .padding(.vertical, 4)
    }
}
