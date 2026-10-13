import Foundation

/// Je stem opnemen voor de sprekerherkenning (`hint-meet voice`): 10 seconden praten, daarna herkent HintMeet
/// je bij naam als alle stemmen op één microfoon binnenkomen.
@MainActor
final class VoiceEnroll: ObservableObject {
    enum State: Equatable { case idle, running(String), done(String), failed(String) }
    @Published private(set) var state: State = .idle
    /// Naam → aantal opgenomen afdrukken (headset, laptop, vergaderruimte, …).
    @Published private(set) var recorded: [String: Int] = [:]
    private var process: Process?

    static let voicesURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/hint-meet/voices.json")

    init() { reload() }

    /// Namen waarvan een stem is opgenomen (uit voices.json, zoals src/hint_meet/speakers.py die schrijft).
    func reload() {
        guard let data = try? Data(contentsOf: Self.voicesURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { recorded = [:]; return }
        // per naam één afdruk (oud formaat: een lijst getallen) of een lijst afdrukken
        recorded = json.mapValues { value in
            guard let list = value as? [Any] else { return 0 }
            return list.first is [Any] ? list.count : 1
        }.filter { $0.value > 0 }
    }

    var isRunning: Bool { if case .running = state { return true } else { return false } }

    func record(_ settings: Settings, name: String) { run(settings, ["--name", name, "--seconds", "10"]
                                                                    + (settings.mic.isEmpty ? [] : ["--mic", settings.mic])) }

    func forget(_ settings: Settings, name: String) { run(settings, ["--name", name, "--forget"]) }

    private func run(_ settings: Settings, _ extra: [String]) {
        guard !isRunning else { return }
        state = .running("Starting…")
        let p = Backend.pythonProcess(settings, ["-m", "hint_meet.cli", "voice"] + extra)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            Task { @MainActor in
                for line in text.split(separator: "\n").map(String.init) { self?.read(line) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                if self.isRunning {
                    self.state = proc.terminationStatus == 0 ? .done("Done") : .failed("Recording failed; see the log")
                }
                self.reload()
            }
        }
        do { try p.run(); process = p } catch { state = .failed("Could not start: \(error.localizedDescription)") }
    }

    private func read(_ line: String) {
        if line.hasPrefix("@step ") {
            state = .running(line.split(separator: " ", maxSplits: 2).dropFirst(2).joined())
        } else if line.hasPrefix("@done ") {
            state = .done(String(line.dropFirst(6)))
        } else if line.hasPrefix("@error ") {
            state = .failed(String(line.dropFirst(7)))
        }
    }
}
