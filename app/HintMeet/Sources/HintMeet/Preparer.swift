import Foundation

/// "KB voorbereiden": draait `hint-meet prepare` (documenten bijwerken, indexeren, spraakherkenning laden),
/// zodat een meeting daarna snel start. Leest de @step/@progress-regels voor de voortgang in het paneel.
@MainActor
final class Preparer: ObservableObject {
    enum State: Equatable { case idle, running, done(String), failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var step = ""
    @Published private(set) var fraction: Double?   // nil: duur onbekend (wieltje)
    @Published private(set) var since: Date?
    private var process: Process?
    private var stopRequested = false
    // stappen zonder eigen voortgang: duur van de vorige keer (per project) als schatting
    private var stepKey = ""
    private var stepStart = Date()
    private var durations: [String: Double] = [:]
    private var durationsKey: String { "prepareDurations." + settings.project }
    private let settings: Settings

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/HintMeet/prepare.log")

    init(settings: Settings) { self.settings = settings }

    var isRunning: Bool { state == .running }

    func start() {
        guard !isRunning, settings.backendReady, !settings.project.isEmpty else { return }
        let p = Backend.pythonProcess(settings, ["-m", "hint_meet.cli", "--project", settings.project, "prepare"])
        try? FileManager.default.createDirectory(at: Preparer.logURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Preparer.logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: Preparer.logURL)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var pending = ""   // regels kunnen over twee blokken verdeeld binnenkomen
        let queue = DispatchQueue(label: "hintmeet.prepare")
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
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            queue.async { try? log?.close() }
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                self.fraction = nil
                self.since = nil
                if proc.terminationReason == .exit && proc.terminationStatus == 0 {
                    self.state = .done(self.step.isEmpty ? "Klaar" : self.step)
                } else if self.stopRequested {
                    self.state = .failed("Gestopt; wat klaar was blijft bewaard, de volgende keer gaat hij verder")
                } else {
                    self.state = .failed("Voorbereiden mislukt (code \(proc.terminationStatus)); zie prepare.log")
                }
            }
        }
        do {
            try p.run()
            process = p
            state = .running
            stopRequested = false
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

    func stop() {   // KB bewaart per batch: de volgende keer verder waar hij was
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
        }
    }
}
