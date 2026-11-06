import Foundation
import HintMeetCore

/// Find op de telefoon buiten een meeting: houdt `hint-meet search --serve` open voor de projecten die de telefoon
/// vraagt (zoals Find Documents op de Mac), en stuurt de antwoorden als `search_results` naar de telefoon. Tijdens
/// het laden meldt hij elke 10 s hoe ver het is (`search_status`), zodat de telefoon blijft wachten. Elke vraag krijgt
/// een antwoord: resultaten, of een fout als het proces stopt. Na 15 minuten zonder vraag stopt het proces (niet
/// tijdens het laden), en ook zodra er een meeting draait (de Gateway roept dan `stop()`).
@MainActor
final class PhoneSearch {
    private struct Request { let id: String; let query: String; var sent = false }

    private let settings: Settings
    private let send: (String) -> Void
    private var process: Process?
    private var input: FileHandle?
    private var projects = ""
    private var ready = false
    private var generation = 0
    /// Alle vragen zonder antwoord: nog niet verstuurd (de KB laadt nog) of verstuurd en wachtend op @results.
    private var requests: [Request] = []
    /// Laatste voortgang van het laden, voor de telefoon.
    private var loadingText = ""
    private var idleTimer: Timer?
    private var heartbeat: Timer?
    static let idleSeconds: TimeInterval = 15 * 60
    static let heartbeatSeconds: TimeInterval = 10
    static let maxQueued = 5
    /// Zo lang mag het laden stil blijven (geen enkele regel) voordat het als vastgelopen geldt.
    static let stallSeconds: TimeInterval = 10 * 60
    private var lastOutput = Date()

    init(settings: Settings, send: @escaping (String) -> Void) {
        self.settings = settings
        self.send = send
    }

    /// `asked`: de projecten die op de telefoon aangevinkt zijn. Onbekend of leeg is een fout: nooit stilletjes in
    /// iets anders zoeken.
    func search(id: String, query: String, projects asked: [String]) {
        let known = Set(settings.projects)
        guard !asked.isEmpty, asked.allSatisfy(known.contains) else { return refuse(id, "no_project") }
        guard settings.backendReady else { return refuse(id, "failed") }
        let key = asked.joined(separator: ",")
        if process == nil || key != projects {
            stop()   // ander project (of geen proces): open vragen krijgen een fout, die horen bij het vorige
            launch(key, label: asked.joined(separator: " + "))
            guard process != nil else { return refuse(id, "failed") }
        }
        requests.append(Request(id: id, query: query))
        while requests.count > Self.maxQueued {   // de telefoon vraagt er één tegelijk; meer is een oude die bleef hangen
            refuse(requests.removeFirst().id, "failed")
        }
        // tijdens het laden de vastloopcontrole niet verschuiven: die telt vanaf de laatste regel van het proces
        if ready || idleTimer == nil { touch() }
        if ready { flush() } else { status(id, loadingText) }
    }

    /// Proces weg; elke open vraag krijgt een fout.
    func stop() {
        let open = requests
        requests = []
        terminate()
        for r in open { refuse(r.id, "failed") }
    }

    /// Antwoord zonder resultaten, met een reden: no_project, busy (er draait een meeting), failed.
    func refuse(_ id: String, _ error: String) {
        sendJSON(["type": "search_results", "id": id, "results": [], "reranked": false, "error": error])
    }

    // MARK: -

    private func terminate() {
        generation += 1   // wat het oude proces nog stuurt, telt niet meer
        idleTimer?.invalidate(); idleTimer = nil
        heartbeat?.invalidate(); heartbeat = nil
        input = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        ready = false
        loadingText = ""
    }

    private func launch(_ key: String, label: String) {
        projects = key
        loadingText = "Loading \(label)…"
        lastOutput = Date()
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
                    Gateway.log("phone search: process ended (\(proc.terminationStatus))")
                    self.stop()
                }
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
            Gateway.log("phone search: loading \(key)")
            heartbeat = Timer.scheduledTimer(withTimeInterval: Self.heartbeatSeconds, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {   // ook in fasen zonder @progress: de telefoon weet dat het nog loopt
                    guard let self, !self.ready, let last = self.requests.last else { return }
                    self.status(last.id, self.loadingText)
                }
            }
        } catch {
            Gateway.log("phone search: could not start: \(error.localizedDescription)")
            terminate()
        }
    }

    private func read(_ line: String) {
        lastOutput = Date()
        if line.hasPrefix("@ready") {
            ready = true
            heartbeat?.invalidate(); heartbeat = nil
            touch()   // de 15 minuten tellen vanaf nu, niet vanaf het begin van het laden
            flush()
        } else if line.hasPrefix("@results "), let data = line.dropFirst(9).data(using: .utf8),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let id = json["id"] as? String { requests.removeAll { $0.id == id } }
            json["type"] = "search_results"
            json.removeValue(forKey: "query")
            sendJSON(json)
        } else if let text = SearchServe.progressText(line) {
            loadingText = text
            // een nieuwe fase of de waarschuwing dat het lang duurt meteen; @progress via de hartslag (elke 10 s)
            if !line.hasPrefix("@progress "), let last = requests.last { status(last.id, text) }
        }
    }

    private func flush() {
        for i in requests.indices where !requests[i].sent {
            let q = requests[i].query.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            input?.write(Data("\(requests[i].id)\t\(q)\n".utf8))   // id: zonder stuurtekens (PhoneRequest.parse)
            requests[i].sent = true
        }
    }

    private func touch() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: ready ? Self.idleSeconds : Self.stallSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.ready { self.stop(); return }
                // nooit midden in het laden afbreken, wel als het laden al 10 minuten niets meer zegt (vastgelopen)
                if Date().timeIntervalSince(self.lastOutput) > Self.stallSeconds {
                    Gateway.log("phone search: loading stalled, stopping")
                    self.stop()
                } else { self.touch() }
            }
        }
    }

    private func status(_ id: String, _ text: String) {
        sendJSON(["type": "search_status", "id": id, "text": text])
    }

    private func sendJSON(_ obj: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj) { send(String(decoding: data, as: UTF8.self)) }
    }
}
