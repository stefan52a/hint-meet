import Combine
import Foundation

/// Start en stopt de Python-pijplijn (`hint-meet live --ui`) als kindproces.
@MainActor
final class Backend: ObservableObject {
    enum State: Equatable { case idle, running, stopping, failed(String) }

    @Published var state: State = .idle
    @Published var lastLines: [String] = []
    @Published private(set) var stoppingSince: Date?
    /// Begin van de lopende meeting, ook van een overgenomen meeting (voor de klok in de kopbalk).
    @Published private(set) var startedAt: Date?
    private var process: Process?
    /// Een meeting die doorliep nadat de app geforceerd gestopt was: geen kindproces meer, alleen zijn pid.
    private var adoptedPID: pid_t?
    /// Starttijd van dat proces: een pid kan na afloop aan een ander proces gegeven worden; dan klopt deze niet meer.
    private var adoptedStart: Double?
    private var adoptedWatch: Timer?
    private let settings: Settings
    let port: Int

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/HintMeet/\(Instance.name("backend")).log")

    /// Welke meeting deze instantie draait (pid, start): na een geforceerde stop neemt de herstarte app hem over.
    static let meetingURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/hint-meet/instances/\(Instance.number).meeting")

    init(settings: Settings, port: Int) {
        self.settings = settings
        self.port = port
        adoptRunningMeeting()
    }

    var isRunning: Bool {
        if let process { return process.isRunning }
        if let adoptedPID { return Self.isAlive(adoptedPID, startedAt: adoptedStart) }
        return false
    }

    /// Leeft pid nog, en is het nog hetzelfde proces (zelfde starttijd)?
    private static func isAlive(_ pid: pid_t, startedAt: Double?) -> Bool {
        guard kill(pid, 0) == 0, let start = processStart(pid) else { return false }
        return startedAt.map { abs($0 - start) < 0.001 } ?? true
    }

    /// Starttijd van een proces volgens de kernel (seconden sinds 1970), of nil als het niet bestaat.
    private static func processStart(_ pid: pid_t) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }

    /// Een signaal alleen aan het proces dat we draaien of overnamen, nooit aan een ander met een hergebruikte pid.
    private func signal(_ sig: Int32) {
        if let process, process.isRunning { kill(process.processIdentifier, sig) }
        else if let adoptedPID, Self.isAlive(adoptedPID, startedAt: adoptedStart) { kill(adoptedPID, sig) }
    }

    /// De app liep vast en is geforceerd gestopt, maar de pijplijn liep door (zie src/hint_meet/survive.py): die
    /// weer overnemen. De overlay verbindt vanzelf en krijgt de hele meeting terug; Stop werkt met een signaal.
    private func adoptRunningMeeting() {
        guard let data = try? Data(contentsOf: Self.meetingURL),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (info["pid"] as? Int).map({ pid_t($0) }),
              case let start = info["pidStart"] as? Double,   // ontbreekt bij een meeting van een oudere versie
              Self.isAlive(pid, startedAt: start),
              Self.isPipeline(pid, port: port)   // en het is echt onze pijplijn
        else {
            try? FileManager.default.removeItem(at: Self.meetingURL)
            return
        }
        adoptedPID = pid
        adoptedStart = start ?? Self.processStart(pid)   // oud meetingbestand: vanaf nu wel vastleggen
        startedAt = (info["started"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        state = .running
        // .common: ook tijdens het afsluiten (terminateLater draait de runloop in een andere modus) zien dat hij klaar is
        let watch = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let pid = self.adoptedPID, !Self.isAlive(pid, startedAt: self.adoptedStart) else { return }
                self.adoptedWatch?.invalidate()
                self.adoptedPID = nil
                self.adoptedStart = nil
                self.startedAt = nil
                self.stoppingSince = nil
                self.state = .idle   // de afloop (verslag, stopped) kwam via de WebSocket
                try? FileManager.default.removeItem(at: Self.meetingURL)
            }
        }
        RunLoop.main.add(watch, forMode: .common)
        adoptedWatch = watch
    }

    /// Is pid onze pijplijn (hint_meet.cli live op deze poort)?
    private static func isPipeline(_ pid: pid_t, port: Int) -> Bool {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return false }
        ps.waitUntilExit()
        let command = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return command.contains("hint_meet.cli") && command.contains(" live ") && command.contains("--port \(port)")
    }

    private func rememberMeeting(_ pid: pid_t) {
        var info: [String: Any] = ["pid": Int(pid), "port": port, "started": Date().timeIntervalSince1970]
        if let start = Self.processStart(pid) { info["pidStart"] = start }
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? data.write(to: Self.meetingURL, options: .atomic)
        }
    }

    /// Python uit de repo-.venv met de omgeving die de pijplijn nodig heeft (ook voor "KB voorbereiden").
    static func pythonProcess(_ settings: Settings, _ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.python)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: settings.repoPath)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = settings.repoPath + "/src"
        env["PYTHONUNBUFFERED"] = "1"
        env["KB_ROOT"] = settings.kbRoot
        // vanuit de Finder gestart kent de app het Homebrew-pad niet; ffmpeg en tesseract staan daar
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        for name in Settings.keyNames {   // Keychain gaat voor .env
            let value = settings.key(name)
            if !value.isEmpty { env[name] = value }
        }
        p.environment = env
        return p
    }

    /// recording: een opname (mp3, m4a, wav, …) in echte tijd afspelen in plaats van de apparaten.
    func start(recording: String? = nil) {
        guard !isRunning else { return }
        guard settings.backendReady else {
            state = .failed("No Python environment in \(settings.repoPath)/.venv")
            return
        }
        guard !settings.project.isEmpty else {
            state = .failed("Choose a project first")
            return
        }
        var args = ["-m", "hint_meet.cli", "--project", settings.project, "live", "--ui", "--port", String(port)]
        if let recording {
            args += ["--audio", recording]
        } else if let wav = ProcessInfo.processInfo.environment["HINT_MEET_TEST_WAV"] {
            args += ["--wav", wav, "--speed", "4"]   // test: opname i.p.v. apparaten
            if let channels = ProcessInfo.processInfo.environment["HINT_MEET_TEST_CHANNELS"] {
                args += ["--channels", channels]   // sprekers per kanaal, bv. "Stefan,Anna"
            }
        } else {
            if !settings.mic.isEmpty { args += ["--mic", settings.mic] }
            if !settings.system.isEmpty { args += ["--system", settings.system] }
        }
        if !settings.summary { args.append("--no-summary") }
        args += ["--language", settings.language]
        let info = settings.meetingInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !info.isEmpty { args += ["--info", info] }

        let p = Backend.pythonProcess(settings, args)
        // valt de app weg, dan schrijft de pijplijn zelf verder in het logboek (src/hint_meet/survive.py)
        p.environment?["HINT_MEET_LOG"] = Backend.logURL.path

        try? FileManager.default.createDirectory(at: Backend.logURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Backend.logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: Backend.logURL)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let logQueue = DispatchQueue(label: "hintmeet.backend.log")   // schrijven en sluiten na elkaar
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            logQueue.async { log?.write(data) }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.remember(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()   // laatste regels niet kwijtraken
            pipe.fileHandleForReading.readabilityHandler = nil
            logQueue.async {
                if !rest.isEmpty { log?.write(rest) }
                try? log?.close()
            }
            let restText = String(decoding: rest, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.process === proc else { return }   // een oude run mag een nieuwe niet wissen
                try? FileManager.default.removeItem(at: Self.meetingURL)
                self.startedAt = nil
                if !restText.isEmpty { self.remember(restText) }
                let clean = proc.terminationReason == .exit && proc.terminationStatus == 0
                self.state = clean ? .idle
                    : .failed("Pipeline stopped (\(proc.terminationReason == .exit ? "code \(proc.terminationStatus)" : "signal \(proc.terminationStatus)")); see the log")
                self.process = nil
                self.stoppingSince = nil
            }
        }
        do {
            try p.run()
            process = p
            state = .running
            startedAt = Date()
            rememberMeeting(p.processIdentifier)
            lastLines = []
        } catch {
            state = .failed("Could not start the pipeline: \(error.localizedDescription)")
        }
    }

    /// Netjes stoppen met SIGINT aan ons eigen kindproces: de pijplijn verwerkt de laatste uitspraak
    /// en maakt het verslag. Geen tijdslimiet: het verslag gaat voor; hangt het, dan is er abort().
    func stop() {
        guard isRunning, state != .stopping else { return }
        state = .stopping
        stoppingSince = Date()
        signal(SIGINT)
    }

    /// "Nu afbreken" tijdens het stoppen: niet langer op het verslag wachten.
    func abort() {
        guard isRunning else { return }
        // hard stoppen alleen dit proces: is er na 3 s al een nieuwe meeting gestart, dan blijft die met rust
        let target = process.map { p in { p.isRunning ? p.processIdentifier : nil } }
            ?? adoptedPID.map { pid in { [start = adoptedStart] in Self.isAlive(pid, startedAt: start) ? pid : nil } }
        signal(SIGTERM)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let pid = target?() { kill(pid, SIGKILL) }
        }
    }

    /// Vangnet bij het echt afsluiten (bv. uitschakelen van de Mac): normaal heeft applicationShouldTerminate
    /// al op het verslag gewacht en draait er niets meer. Anders hooguit 10 s, dan beëindigen, desnoods hard.
    func stopNow() {
        guard isRunning else { return }
        signal(SIGINT)
        let deadline = Date().addingTimeInterval(10)
        while isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if isRunning { signal(SIGTERM); Thread.sleep(forTimeInterval: 2) }
        if isRunning { signal(SIGKILL) }
    }

    private func remember(_ text: String) {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.contains("\u{1b}[K") && !$0.isEmpty }
        lastLines = Array((lastLines + lines).suffix(8))
    }
}
