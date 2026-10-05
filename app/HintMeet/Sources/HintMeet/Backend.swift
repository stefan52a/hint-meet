import Combine
import Foundation

/// Start en stopt de Python-pijplijn (`hint-meet live --ui`) als kindproces.
@MainActor
final class Backend: ObservableObject {
    enum State: Equatable { case idle, running, stopping, failed(String) }

    @Published var state: State = .idle
    @Published var lastLines: [String] = []
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

    /// recording: een opname (mp3, m4a, wav, …) in echte tijd afspelen in plaats van de apparaten.
    func start(recording: String? = nil) {
        guard !isRunning else { return }
        guard settings.backendReady else {
            state = .failed("Geen Python-omgeving in \(settings.repoPath)/.venv")
            return
        }
        guard !settings.project.isEmpty else {
            state = .failed("Kies eerst een project")
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
                    : .failed("Pijplijn gestopt (\(proc.terminationReason == .exit ? "code \(proc.terminationStatus)" : "signaal \(proc.terminationStatus)")); zie het logboek")
                self.process = nil
            }
        }
        do {
            try p.run()
            process = p
            state = .running
            lastLines = []
        } catch {
            state = .failed("Kon de pijplijn niet starten: \(error.localizedDescription)")
        }
    }

    /// Netjes stoppen met SIGINT aan ons eigen kindproces: de pijplijn verwerkt de laatste uitspraak
    /// en maakt het verslag. Lukt dat niet binnen 60 s, dan beëindigen.
    func stop() {
        guard let p = process, p.isRunning else { return }
        state = .stopping
        p.interrupt()
        Task { @MainActor in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !p.isRunning { return }
            }
            p.terminate()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    /// Bij afsluiten van de app: hooguit 10 s wachten (verslag), dan beëindigen, desnoods hard.
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
