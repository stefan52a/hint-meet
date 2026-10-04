import Foundation

/// WebSocket naar de pijplijn op 127.0.0.1; maakt zelf opnieuw verbinding als die (her)start.
@MainActor
final class Connection {
    private let port: Int
    private let store: HintStore
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)

    init(port: Int, store: HintStore) {
        self.port = port
        self.store = store
    }

    /// Bij elke poging opnieuw gelezen: de backend maakt de sleutel aan bij zijn eerste start.
    private var url: URL {
        let tokenFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/hint-meet/ws-token")
        let token = (try? String(contentsOf: tokenFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts = URLComponents(string: "ws://127.0.0.1:\(port)/")!
        parts.queryItems = [URLQueryItem(name: "token", value: token)]
        return parts.url!
    }

    func start() { connect() }

    private func connect() {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    self.store.connected = true
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.store.handle(obj)
                    }
                    self.receive(task)
                case .failure:
                    self.store.connected = false
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.connect()
                }
            }
        }
    }

    func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }
}
