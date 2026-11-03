import Combine
import Foundation
import HintMeetCore
import Network

/// WebSocket naar de pijplijn op 127.0.0.1 (de hub of de audiobron), voor de gateway. Probeert elke seconde
/// opnieuw tot hij er is; `reconnect()` begint een nieuwe verbinding (dan speelt de hub zijn backlog opnieuw af
/// en stuurt de audiobron opnieuw audio_ready).
@MainActor
final class Upstream {
    private let url: () -> URL
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var running = false
    var onText: ((String) -> Void)?

    init(url: @escaping () -> URL) { self.url = url }

    func start() {
        guard !running else { return }
        running = true
        connect()
    }

    func stop() {
        running = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func reconnect() {
        guard running else { return }
        task?.cancel(with: .goingAway, reason: nil)
        connect()
    }

    private func connect() {
        let t = session.webSocketTask(with: url())
        t.maximumMessageSize = 4 << 20   // een verslag kan groot zijn
        task = t
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.onText?(text) }
                    self.receive(t)
                case .failure:
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard self.running, self.task === t else { return }
                    self.connect()
                }
            }
        }
    }

    func send(_ text: String) { task?.send(.string(text)) { _ in } }
    func send(_ data: Data) { task?.send(.data(data)) { _ in } }
}

/// Eén telefoon-verbinding (al geautoriseerd tijdens de handshake).
@MainActor
final class PhoneLink {
    let conn: NWConnection
    init(_ conn: NWConnection) { self.conn = conn }

    func send(_ text: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// Ontvangt berichten tot de verbinding dicht is: text → onText, binair → onData.
    func receive(onText: @escaping (String) -> Void, onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        conn.receiveMessage { [weak self] data, ctx, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if error != nil || meta?.opcode == .close {
                    onClose()
                    return
                }
                if let data {
                    if meta?.opcode == .text { onText(String(decoding: data, as: UTF8.self)) }
                    else if meta?.opcode == .binary { onData(data) }
                }
                self.receive(onText: onText, onData: onData, onClose: onClose)
            }
        }
    }

    func close() { conn.cancel() }
}

/// Telefoon-companion: luistert op het Tailscale-adres van deze Mac (nooit op andere netwerken), start en stopt
/// meetings voor de telefoon en zet zijn verbinding door naar de pijplijn: tekst naar de hub (overlay-poort),
/// audio naar de audiobron (poort + 100). Alleen instantie 1 heeft een gateway.
@MainActor
final class Gateway: ObservableObject {
    static let port: UInt16 = 8790

    @Published private(set) var listening: String?   // "100.x.y.z:8790" of nil
    @Published private(set) var problem: String?

    private let settings: Settings
    private let backend: Backend
    private var listener: NWListener?
    private var bound: String?
    private var monitor = TailnetMonitor()
    private var timer: Timer?
    private var phones: [ObjectIdentifier: PhoneLink] = [:]
    private var pending: [ObjectIdentifier: PhoneLink] = [:]   // nog in de handshake
    /// Meeting die deze gateway voor de telefoon startte (nil: geen, of een meeting die op de Mac zelf begon).
    private var meeting: String?
    private var startedAtMs: Int64?
    private var last: GatewayState.Last?
    private var seenRequests: [String] = []   // request_id's: een herhaalde start start nooit een tweede meeting
    private var hub: Upstream?
    private var source: Upstream?
    private let keepAwake = KeepAwake()
    private var watch: AnyCancellable?
    private var dnsName: String?

    /// Alleen voor tests op deze Mac zonder Tailscale (zie GatewayTestMode).
    private let testHost = GatewayTestMode.host

    init(settings: Settings, backend: Backend) {
        self.settings = settings
        self.backend = backend
        // @Published meldt vóór de wijziging: pas daarna kijken
        watch = backend.$state.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.backendChanged() } }
        }
        setEnabled(settings.phoneEnabled)
    }

    // MARK: aan/uit en het adres

    func setEnabled(_ on: Bool) {
        if settings.phoneEnabled != on { settings.phoneEnabled = on }
        timer?.invalidate()
        timer = nil
        if on {
            let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            poll()
        } else {
            unbind()
            problem = nil
        }
        keepAwake.update(enabled: on)
    }

    private func poll() {
        let current = testHost ?? Tailnet.currentAddress()
        if current == nil { problem = "Tailscale isn't running on this Mac" }
        else if listener != nil, listening != nil { problem = nil }
        switch monitor.decide(current: current, bound: bound) {
        case .bind(let address): bind(address)
        case .unbind: unbind()
        case .none: break
        }
        keepAwake.update(enabled: true)
    }

    private func bind(_ address: String) {
        unbind()
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        // sleutel controleren tijdens de handshake: zonder goede sleutel gaat er niets terug
        ws.setClientRequestHandler(.main) { [weak self] _, headers in
            let ok = MainActor.assumeIsolated {
                self.map { PhoneAuth.authorized(headers: headers, token: $0.settings.phoneToken) } ?? false
            }
            return NWProtocolWebSocket.Response(status: ok ? .accept : .reject, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in MainActor.assumeIsolated { self?.accept(conn) } }
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.listener === l else { return }
                    switch state {
                    case .ready:
                        self.listening = "\(address):\(Self.port)"
                        self.problem = nil
                    case .failed(let error):
                        self.problem = "Couldn't listen on \(address):\(Self.port): \(error.localizedDescription)"
                        self.unbind()   // volgende ronde opnieuw proberen
                    default: break
                    }
                }
            }
            listener = l
            bound = address
            l.start(queue: .main)
        } catch {
            problem = "Couldn't listen on \(address):\(Self.port): \(error.localizedDescription)"
        }
    }

    private func unbind() {
        listener?.cancel()
        listener = nil
        bound = nil
        listening = nil
        closeAllPhones()
    }

    private func closeAllPhones() {
        for p in Array(phones.values) + Array(pending.values) { p.close() }
        phones.removeAll()
        pending.removeAll()
    }

    // MARK: koppelen

    /// Inhoud van de koppel-QR. Met de MagicDNS-naam als die er is: die blijft gelijk als het adres wisselt.
    func pairingURL() -> String? {
        guard let host = magicDNSName() ?? bound else { return nil }
        return Pairing.url(host: host, port: Int(Self.port), token: settings.phoneToken)
    }

    /// Nieuwe sleutel: de oude telefoon komt er niet meer in, en open verbindingen gaan meteen dicht.
    @discardableResult
    func newPairing() -> String? {
        settings.renewPhoneToken()
        closeAllPhones()
        return pairingURL()
    }

    private func magicDNSName() -> String? {
        if testHost != nil { return nil }
        if let dnsName { return dnsName }
        let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                          "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["status", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        dnsName = Tailnet.dnsName(fromStatusJSON: data)
        return dnsName
    }

    // MARK: telefoons

    private func peerAllowed(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        var ip = "\(host)"
        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }   // interface-achtervoegsel
        if ip.hasPrefix("::ffff:") { ip = String(ip.dropFirst(7)) }
        return Tailnet.isTailnet(ip) || (testHost != nil && ip == "127.0.0.1")
    }

    private func accept(_ conn: NWConnection) {
        guard peerAllowed(conn.endpoint) else {   // niets sturen, gewoon dicht
            conn.cancel()
            return
        }
        let link = PhoneLink(conn)
        let id = ObjectIdentifier(link)
        pending[id] = link   // vasthouden tot de handshake klaar is (daarna in phones)
        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    if let link = self.pending.removeValue(forKey: id) { self.joined(link) }
                case .failed, .cancelled:
                    self.pending[id] = nil
                    self.phones[id] = nil
                    conn.stateUpdateHandler = nil
                default: break
                }
            }
        }
        conn.start(queue: .main)
    }

    private func joined(_ link: PhoneLink) {
        let id = ObjectIdentifier(link)
        phones[id] = link
        link.receive(onText: { [weak self, weak link] text in
            guard let self, let link else { return }
            self.handle(text, from: link)
        }, onData: { [weak self] data in
            self?.source?.send(data)
        }, onClose: { [weak self, weak link] in
            guard let self, let link else { return }
            self.phones[ObjectIdentifier(link)] = nil
            link.close()
        })
        link.send(state().json())
        if meeting != nil {   // opnieuw verbonden: backlog van de hub, en audio_ready voor deze telefoon
            hub?.reconnect()
            source?.reconnect()
        }
    }

    private func handle(_ text: String, from link: PhoneLink) {
        switch PhoneRequest.parse(text) {
        case .projects:
            let msg: [String: Any] = ["type": "projects", "items": settings.projects, "selected": settings.selectedProjects]
            if let data = try? JSONSerialization.data(withJSONObject: msg) { link.send(String(decoding: data, as: UTF8.self)) }
        case .state:
            link.send(state().json())
        case let .start(requestID, projects, language, info):
            start(requestID: requestID, projects: projects, language: language, info: info, from: link)
        case .toHub(let raw):
            hub?.send(raw)
        case .invalid:
            break
        }
    }

    private func start(requestID: String, projects: [String], language: String, info: String, from link: PhoneLink) {
        if seenRequests.contains(requestID) || backend.isRunning {   // al gestart, of iets anders draait
            link.send(state().json())
            return
        }
        seenRequests = Array((seenRequests + [requestID]).suffix(50))
        let known = Set(settings.projects)
        guard projects.allSatisfy(known.contains) else {
            sendStatus("Unknown project: \(projects.filter { !known.contains($0) }.joined(separator: ", "))", to: link)
            link.send(state().json())
            return
        }
        let id = meetingID()
        meeting = id
        startedAtMs = nil
        last = nil
        backend.start(phone: .init(meeting: id, projects: projects, language: language, info: info))
        if backend.isRunning {
            startUpstreams()
        } else {
            meeting = nil
            if case .failed(let why) = backend.state { sendStatus(why, to: link) }
        }
        pushState()
    }

    private func sendStatus(_ text: String, to link: PhoneLink) {
        let msg: [String: Any] = ["type": "status", "text": text]
        if let data = try? JSONSerialization.data(withJSONObject: msg) { link.send(String(decoding: data, as: UTF8.self)) }
    }

    // MARK: de pijplijn

    private var pipelineToken: String {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/hint-meet/ws-token")
        return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func localURL(_ port: Int) -> URL {
        var parts = URLComponents(string: "ws://127.0.0.1:\(port)/")!
        parts.queryItems = [URLQueryItem(name: "token", value: pipelineToken)]   // bij elke poging opnieuw gelezen
        return parts.url!
    }

    private func startUpstreams() {
        let hub = Upstream { [unowned self] in self.localURL(self.backend.port) }
        hub.onText = { [weak self] text in self?.broadcast(text) }
        let source = Upstream { [unowned self] in self.localURL(self.backend.phonePort) }
        source.onText = { [weak self] text in
            guard let self else { return }
            if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               obj["type"] as? String == "audio_ready",
               let ms = (obj["started_at_ms"] as? NSNumber)?.int64Value {
                let first = self.startedAtMs == nil
                self.startedAtMs = ms
                if first { self.pushState() }
            }
            self.broadcast(text)
        }
        self.hub = hub
        self.source = source
        hub.start()
        source.start()
    }

    private func stopUpstreams() {
        hub?.stop()
        source?.stop()
        hub = nil
        source = nil
    }

    private func broadcast(_ text: String) {
        for p in phones.values { p.send(text) }
    }

    private func backendChanged() {
        if let id = meeting, !backend.isRunning {   // onze meeting is voorbij (netjes, of de pijplijn viel weg)
            let logs = URL(fileURLWithPath: settings.repoPath).appendingPathComponent("logs")
            last = LastResult.read(logs: logs, meeting: id)
            stopUpstreams()
            meeting = nil
            startedAtMs = nil
        }
        pushState()
    }

    private func state() -> GatewayState {
        let running = backend.isRunning
        let phase: String
        if !running { phase = "idle" }
        else if meeting == nil { phase = "running" }
        else if backend.state == .stopping { phase = "stopping" }
        else if startedAtMs == nil { phase = "starting" }
        else { phase = "running" }
        return GatewayState(phase: phase, meeting: running ? meeting : nil, startedAtMs: running ? startedAtMs : nil,
                            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                            busyElsewhere: running && meeting == nil, last: last)
    }

    private func pushState() {
        let json = state().json()
        for p in phones.values { p.send(json) }
    }
}
