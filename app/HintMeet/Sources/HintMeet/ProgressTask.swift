import Foundation

/// Een Python-taak met voortgang in beeld: "KB laden" (`hint-meet prepare`) en "Documenten omzetten"
/// (tools/kb_prep.py). Leest de regels "@step <sleutel> <tekst>" en "@progress <klaar> <totaal> <tekst>";
/// de rest gaat naar het logboek. Stappen zonder eigen voortgang krijgen een schatting uit de vorige keer.
@MainActor
final class ProgressTask: ObservableObject {
    enum State: Equatable { case idle, running, done(String), failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var step = ""
    @Published private(set) var fraction: Double?   // nil: duur onbekend (schatting of wieltje)
    @Published private(set) var since: Date?
    private var process: Process?
    private var stopRequested = false
    private var summary: String?   // "Klaar: 3 omgezet, …" van kb_prep
    private var warnings: [String] = []   // "@warn …": klaar, maar met een kanttekening
    private var lastMessage = ""          // laatste gewone regel: bij een fout de uitleg van het script zelf
    private var stepKey = ""
    private var stepStart = Date()
    private var durations: [String: Double] = [:]
    private var durationsKey = ""
    let logURL: URL

    init(logName: String) {
        logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HintMeet/\(logName).log")
    }

    var isRunning: Bool { state == .running }

    /// okCodes: exitcodes die als geslaagd tellen (kb_prep: 1 = enkele bestanden mislukt, de rest is klaar).
    func start(_ settings: Settings, args: [String], estimateKey: String, okCodes: Set<Int32> = [0], what: String) {
        guard !isRunning, settings.backendReady else { return }
        let p = Backend.pythonProcess(settings, args)
        p.environment?["KB_PREP_MACHINE"] = "1"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var pending = ""   // regels kunnen over twee blokken verdeeld binnenkomen
        let queue = DispatchQueue(label: "hintmeet.task")
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            queue.async {
                log?.write(data)
                pending += String(decoding: data, as: UTF8.self)
                var lines = pending.components(separatedBy: "\n")
                pending = lines.removeLast()
                Task { @MainActor [weak self] in lines.forEach { self?.read($0) } }
            }
        }
        let logName = logURL.lastPathComponent
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            queue.async { try? log?.close() }
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                self.fraction = nil
                self.since = nil
                if self.stopRequested {
                    self.state = .failed("Gestopt; wat klaar was blijft bewaard, de volgende keer gaat hij verder")
                } else if proc.terminationReason == .exit && okCodes.contains(proc.terminationStatus) {
                    let done = self.summary ?? (self.step.isEmpty ? "Klaar" : self.step)
                    self.state = .done(([done] + self.warnings.map { "⚠ " + $0 }).joined(separator: "\n"))
                } else if proc.terminationReason == .exit && !self.lastMessage.isEmpty {
                    self.state = .failed("\(what) niet gelukt: \(self.lastMessage)")   // bv. al een kb_prep bezig
                } else {
                    self.state = .failed("\(what) mislukt (code \(proc.terminationStatus)); zie \(logName)")
                }
            }
        }
        do {
            try p.run()
            process = p
            state = .running
            stopRequested = false
            summary = nil
            warnings = []
            lastMessage = ""
            durationsKey = estimateKey
            durations = UserDefaults.standard.dictionary(forKey: durationsKey) as? [String: Double] ?? [:]
            stepKey = "start"
            stepStart = Date()
            step = "Starten…"
            fraction = nil
            since = Date()
        } catch {
            state = .failed("Kon niet starten: \(error.localizedDescription)")
        }
    }

    func stop() {   // beide taken bewaren tussendoor: de volgende keer verder waar hij was
        guard let p = process, p.isRunning else { return }
        stopRequested = true
        p.interrupt()
    }

    /// Geschatte voortgang van de huidige stap op tijdstip `now`, als die stap geen eigen voortgang meldt
    /// en de vorige keer is gemeten. Blijft onder 95%: een schatting mag niet "klaar" beloven.
    func estimate(at now: Date) -> (fraction: Double, left: Double)? {
        guard isRunning, fraction == nil, let expected = durations[stepKey], expected >= 2 else { return nil }
        let elapsed = now.timeIntervalSince(stepStart)
        return (min(elapsed / expected, 0.95), max(expected - elapsed, 0))
    }

    private func read(_ line: String) {
        if line.hasPrefix("@step ") {
            let parts = line.dropFirst(6).split(separator: " ", maxSplits: 1).map(String.init)
            durations[stepKey] = Date().timeIntervalSince(stepStart)   // de vorige stap is klaar: duur onthouden
            UserDefaults.standard.set(durations, forKey: durationsKey)
            stepKey = parts.first ?? ""
            stepStart = Date()
            step = parts.count > 1 ? parts[1] : ""
            fraction = nil
        } else if line.hasPrefix("@progress ") {
            let parts = line.dropFirst(10).split(separator: " ", maxSplits: 2).map(String.init)
            if parts.count == 3, let done = Double(parts[0]), let total = Double(parts[1]), total > 0 {
                fraction = done / total
                step = parts[2]
            }
        } else if line.hasPrefix("@warn ") {
            warnings.append(String(line.dropFirst(6)))
        } else if line.hasPrefix("Klaar:") {
            summary = line
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty && !line.hasPrefix("  ✓") {
            lastMessage = line.trimmingCharacters(in: .whitespaces)
        }
    }
}

extension ProgressTask {
    /// "KB laden": documenten bijwerken, indexeren, spraakherkenning laden voor de gekozen projecten.
    func startPrepare(_ settings: Settings) {
        guard !settings.project.isEmpty else { return }
        start(settings, args: ["-m", "hint_meet.cli", "--project", settings.project, "prepare"],
              estimateKey: "prepareDurations." + settings.project, what: "KB laden")
    }

    /// tools/kb_prep.py met zijn opties: bronmap → KB_ROOT/<project>.
    func startKBPrep(_ settings: Settings, source: String, project: String, force: Bool, noOCR: Bool) {
        var args = [settings.repoPath + "/tools/kb_prep.py", source, "--project", project]
        if force { args.append("--force") }
        if noOCR { args.append("--no-ocr") }
        start(settings, args: args, estimateKey: "kbprepDurations." + project, okCodes: [0, 1],
              what: "Documenten omzetten")
    }
}
