import Combine
import Foundation

/// Start en stopt de Python-pijplijn (`hint-meet live --ui`) als kindproces.
@MainActor
final class Backend: ObservableObject {
    enum State: Equatable { case idle, running, stopping, failed(String) }

    @Published var state: State = .idle
    @Published var lastLines: [String] = []
    @Published private(set) var stoppingSince: Date?
    private var process: Process?
    private let settings: Settings
    let port: Int

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/HintMeet/backend.log")

    init(settings: Settings, port: Int) {
        self.settings = settings
        self.port = port
    }

    var isRunning: Bool { process?.isRunning ?? false }

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
        } else {
            if !settings.mic.isEmpty { args += ["--mic", settings.mic] }
            if !settings.system.isEmpty { args += ["--system", settings.system] }
        }
        if !settings.summary { args.append("--no-summary") }
        let info = settings.meetingInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !info.isEmpty { args += ["--info", info] }

        let p = Backend.pythonProcess(settings, args)

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
            lastLines = []
        } catch {
            state = .failed("Could not start the pipeline: \(error.localizedDescription)")
        }
    }

    /// Netjes stoppen met SIGINT aan ons eigen kindproces: de pijplijn verwerkt de laatste uitspraak
    /// en maakt het verslag. Geen tijdslimiet: het verslag gaat voor; hangt het, dan is er abort().
    func stop() {
        guard let p = process, p.isRunning, state != .stopping else { return }
        state = .stopping
        stoppingSince = Date()
        p.interrupt()
    }

    /// "Nu afbreken" tijdens het stoppen: niet langer op het verslag wachten.
    func abort() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    /// Vangnet bij het echt afsluiten (bv. uitschakelen van de Mac): normaal heeft applicationShouldTerminate
    /// al op het verslag gewacht en draait er niets meer. Anders hooguit 10 s, dan beëindigen, desnoods hard.
    func stopNow() {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); Thread.sleep(forTimeInterval: 2) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    private func remember(_ text: String) {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.contains("\u{1b}[K") && !$0.isEmpty }
        lastLines = Array((lastLines + lines).suffix(8))
    }
}
