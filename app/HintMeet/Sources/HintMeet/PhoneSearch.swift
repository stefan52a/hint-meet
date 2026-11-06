import Foundation

/// Find op de telefoon buiten een meeting: houdt `hint-meet search --serve` open voor de projecten die de telefoon
/// vraagt (zoals Find Documents op de Mac), en stuurt de antwoorden als `search_results` naar de telefoon. Tijdens
/// het laden meldt hij de voortgang met `search_status`. Na 15 minuten zonder vraag stopt het proces weer.
@MainActor
final class PhoneSearch {
    private let settings: Settings
    private let send: (String) -> Void
    private var process: Process?
    private var input: FileHandle?
    private var projects = ""
    private var ready = false
    private var generation = 0
    /// Vragen die wachten tot de kennisbank geladen is (alleen de laatste telt voor de telefoon, maar ze kosten weinig).
    private var waiting: [(id: String, query: String)] = []
    private var idleTimer: Timer?
    static let idleSeconds: TimeInterval = 15 * 60

    init(settings: Settings, send: @escaping (String) -> Void) {
        self.settings = settings
        self.send = send
    }

    func search(id: String, query: String, projects asked: [String]) {
        let known = Set(settings.projects)
        // niets gevraagd: wat de Mac koos; wel gevraagd maar onbekend: een fout, niet stilletjes ergens anders zoeken
        let list = asked.isEmpty ? settings.selectedProjects : asked
        guard !list.isEmpty, list.allSatisfy(known.contains) else { return reply(id, error: "no_project") }
        guard settings.backendReady else { return reply(id, error: "failed") }
        let key = list.joined(separator: ",")
        if process?.isRunning == true && key == projects && ready {
            write(id, query)
            touch()
            return
        }
        if process?.isRunning != true || key != projects {
            restart(key)
            guard process != nil else { return reply(id, error: "failed") }   // kon niet starten
        }
        waiting.append((id, query))
        while waiting.count > 5 { reply(waiting.removeFirst().id, error: "failed") }
        touch()   // na restart(): die zet de timer stil
        status(id, "Loading \(list.joined(separator: " + "))…")
    }

    func stop() {
        generation += 1
        idleTimer?.invalidate()
        idleTimer = nil
        input = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        ready = false
        for w in waiting { reply(w.id, error: "failed") }
        waiting = []
    }

    // MARK: -

    private func restart(_ key: String) {
        let pending = key == projects ? waiting : []   // zelfde project (proces viel weg): de vragen blijven staan
        if key != projects { for w in waiting { reply(w.id, error: "failed") } }
        waiting = []
        stop()
        waiting = pending
        projects = key
        let p = Backend.pythonProcess(settings, ["-m", "hint_meet.cli", "--project", key, "search", "--serve"])
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inp
        generation += 1
        let gen = generation
        let lines = LineSplitter()
        let queue = DispatchQueue(label: "hintmeet.phonesearch")
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            queue.async {
                let complete = lines.feed(data, atEnd: false)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == gen else { return }
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
                    self.input = nil
                    self.ready = false
                    for w in self.waiting { self.reply(w.id, error: "failed") }
                    self.waiting = []
                }
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
            Gateway.log("phone search: loading \(key)")
        } catch {
            Gateway.log("phone search: could not start: \(error.localizedDescription)")
            for w in waiting { reply(w.id, error: "failed") }
            waiting = []
        }
    }

    private func read(_ line: String) {
        if line.hasPrefix("@ready") {
            ready = true
            let todo = waiting
            waiting = []
            for w in todo { write(w.id, w.query) }
        } else if line.hasPrefix("@results "), let data = line.dropFirst(9).data(using: .utf8),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json["type"] = "search_results"
            json.removeValue(forKey: "query")
            sendJSON(json)
        } else if line.hasPrefix("@step ") || line.hasPrefix("@progress "), let last = waiting.last {
            // "@step <sleutel> <tekst>" of "@progress <klaar> <totaal> <tekst>": alleen de tekst
            let parts = line.split(separator: " ", maxSplits: line.hasPrefix("@step ") ? 2 : 3)
            if let text = parts.last, parts.count >= 3 { status(last.id, String(text)) }
        }
    }

    private func write(_ id: String, _ query: String) {
        let q = query.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        let rid = id.filter { !$0.isNewline && $0 != "\t" }
        input?.write(Data("\(rid)\t\(q)\n".utf8))
    }

    private func touch() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    private func reply(_ id: String, error: String) {
        sendJSON(["type": "search_results", "id": id, "results": [], "reranked": false, "error": error])
    }

    private func status(_ id: String, _ text: String) {
        sendJSON(["type": "search_status", "id": id, "text": text])
    }

    private func sendJSON(_ obj: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj) { send(String(decoding: data, as: UTF8.self)) }
    }
}
