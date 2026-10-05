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
    var sendStop: (() -> Void)?

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/HintMeet/backend.log")

    init(settings: Settings, port: Int) {
        self.settings = settings
        self.port = port
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
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
        if let wav = ProcessInfo.processInfo.environment["HINT_MEET_TEST_WAV"] {
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
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            log?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.remember(text) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                try? log?.close()
                let code = proc.terminationStatus
                if self.state == .stopping || code == 0 {
                    self.state = .idle
                } else {
                    self.state = .failed("Pijplijn gestopt (code \(code)); zie het logboek")
                }
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

    /// Netjes stoppen: via de overlay-verbinding (dan komt het verslag nog), anders na 60 s hard.
    func stop() {
        guard let p = process, p.isRunning else { return }
        state = .stopping
        sendStop?()
        Task { @MainActor in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !p.isRunning { return }
            }
            p.interrupt()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if p.isRunning { p.terminate() }
        }
    }

    func stopNow() {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        p.waitUntilExit()
    }

    private func remember(_ text: String) {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.contains("\u{1b}[K") && !$0.isEmpty }
        lastLines = Array((lastLines + lines).suffix(8))
    }
}
