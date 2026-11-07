import Combine
import Foundation
import HintMeetCore
import Network
import UniformTypeIdentifiers

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
    /// Melding over de achtergronddienst die HintMeet start als de app dicht is (nil = in orde of uit).
    @Published private(set) var wakeProblem: String?

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
    /// Find op de telefoon buiten een meeting: een eigen zoekproces, los van Find Documents op de Mac.
    private lazy var phoneSearch = PhoneSearch(settings: settings) { [weak self] text in self?.broadcast(text) }
    private var source: Upstream?
    private let keepAwake = KeepAwake()
    private var watch: AnyCancellable?
    private var dnsName: String?

    /// Alleen voor tests op deze Mac zonder Tailscale (zie GatewayTestMode).
    private let testHost = GatewayTestMode.host
    /// "Add Folder" vanaf de telefoon: de app zet de map om (zoals Add Folder… op de Mac). Geeft het project, of
    /// een fout ("busy" als er al iets wordt omgezet of geladen).
    private var addFolder: ((URL) -> (project: String?, error: String?))?
    /// Project verwijderen (de app vraagt niets meer: de telefoon heeft al bevestigd). nil = gelukt, anders de fout.
    private var removeProject: ((String) -> String?)?
    private var preparer: ProgressTask?
    private var preparerWatch: [AnyCancellable] = []
    private var lastTaskSent = Date.distantPast

    init(settings: Settings, backend: Backend) {
        self.settings = settings
        self.backend = backend
        // @Published meldt vóór de wijziging: pas daarna kijken
        watch = backend.$state.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.backendChanged() } }
        }
        setEnabled(settings.phoneEnabled)
    }

    /// ~/Library/Logs/HintMeet/gateway.log: wie er geweigerd werd (om koppelproblemen te kunnen zien).
    nonisolated static func log(_ text: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HintMeet/gateway.log")
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
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
        wakeProblem = PhoneWake.update(on: on && settings.phoneWake)
    }

    /// "Also when HintMeet is closed" aan of uit.
    func setWake(_ on: Bool) {
        if settings.phoneWake != on { settings.phoneWake = on }
        wakeProblem = PhoneWake.update(on: settings.phoneEnabled && on)
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
            if !ok { Gateway.log("handshake refused (wrong or missing key)") }
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
                        self.refreshDNSName()
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
        let token = settings.phoneToken
        guard !token.isEmpty, let host = magicDNSName() ?? bound else { return nil }
        return Pairing.url(host: host, port: Int(Self.port), token: token)
    }

    /// Nieuwe sleutel: de oude telefoon komt er niet meer in, en open verbindingen gaan meteen dicht.
    /// Kan de nieuwe sleutel niet bewaard worden, dan blijft de oude geldig en geeft dit nil.
    @discardableResult
    func newPairing() -> String? {
        guard settings.renewPhoneToken() != nil else {
            problem = "Couldn't save a new phone key (~/Library/Application Support/hint-meet/phone-token)"
            return nil
        }
        closeAllPhones()
        return pairingURL()
    }

    /// Uit de cache; refreshDNSName() vult hem op de achtergrond (een vastgelopen tailscale mag de app niet ophouden).
    private func magicDNSName() -> String? { testHost == nil ? dnsName : nil }

    private func refreshDNSName() {
        guard testHost == nil else { return }
        let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                          "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["status", "--json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)   // hooguit 5 s
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let name = Tailnet.dnsName(fromStatusJSON: data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.dnsName != name { self.dnsName = name; self.objectWillChange.send() }
                }
            }
        }
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
            Self.log("refused peer \(conn.endpoint)")
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
        // één telefoon tegelijk: de nieuwste wint (de oude verbinding is meestal half-open na een netwerkwissel)
        for (other, old) in phones where other != id { old.close() }
        phones = [id: link]
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

    /// Door de app na het starten: Add Folder vanaf de telefoon, en de voortgang van omzetten/laden naar de telefoon.
    func attach(preparer: ProgressTask, addFolder: @escaping (URL) -> (project: String?, error: String?),
                removeProject: @escaping (String) -> String?) {
        self.preparer = preparer
        self.addFolder = addFolder
        self.removeProject = removeProject
        preparerWatch = [
            preparer.$state.removeDuplicates().sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.pushTask(force: true) } }
            },
            preparer.$step.combineLatest(preparer.$fraction).sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.pushTask(force: false) } }
            },
        ]
    }

    /// `kb_task`: wat de Mac aan het omzetten of laden is (Add Folder, Preload KB). Voortgang hooguit elke 2 s;
    /// klaar of mislukt meteen, met daarna de nieuwe lijst projecten.
    private func taskJSON() -> String? {
        guard let p = preparer else { return nil }
        var msg: [String: Any] = ["type": "kb_task", "title": p.title, "step": p.step]
        if let f = p.fraction { msg["fraction"] = f }
        switch p.state {
        case .idle: msg["state"] = "idle"
        case .running: msg["state"] = "running"
        case .done(let text): msg["state"] = "done"; msg["message"] = text
        case .failed(let text): msg["state"] = "failed"; msg["message"] = text
        }
        return Self.json(msg)
    }

    private func pushTask(force: Bool) {
        guard force || Date().timeIntervalSince(lastTaskSent) >= 2, let json = taskJSON() else { return }
        lastTaskSent = Date()
        broadcast(json)
        if force, let p = preparer, !p.isRunning { broadcast(projectsJSON()) }
    }

    /// De lijst projecten is veranderd (toegevoegd of verwijderd, ook op de Mac): naar alle telefoons.
    func projectsChanged() { broadcast(projectsJSON()) }

    private func projectsJSON() -> String {
        Self.json(["type": "projects", "items": settings.projects, "selected": settings.selectedProjects])
    }

    nonisolated private static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func listDirs(id: String, path: String?, to link: PhoneLink) {
        let home = NSHomeDirectory()
        guard let l = FolderBrowser.list(path ?? FolderBrowser.defaultPath(home: home), home: home) else {
            link.send(Self.json(["type": "dirs", "id": id, "error": "not_allowed"]))
            return
        }
        link.send(Self.json(["type": "dirs", "id": id, "path": l.path, "parent": l.parent ?? NSNull(), "dirs": l.dirs,
                             "home": home]))
    }

    private func addFolder(id: String, path: String, to link: PhoneLink) {
        let reply = { (ok: Bool, project: String?, error: String?) in
            link.send(Self.json(["type": "folder_added", "id": id, "ok": ok, "project": project ?? NSNull(),
                                 "error": error ?? NSNull()]))
        }
        guard !backend.isRunning else { return reply(false, nil, "busy") }
        guard let real = FolderBrowser.resolve(path, home: NSHomeDirectory()), let addFolder else {
            return reply(false, nil, "not_allowed")
        }
        let result = addFolder(URL(fileURLWithPath: real))
        Gateway.log("phone: add folder \(real) → \(result.project ?? result.error ?? "?")")
        reply(result.error == nil, result.project, result.error)
        pushTask(force: true)
    }

    /// Een document naar deze telefoon (base64 in JSON); alleen uit de kennisbanken, hooguit 12 MB.
    private func sendDoc(id: String, path: String, to link: PhoneLink) {
        let kbRoot = settings.kbRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let msg: [String: Any]
            if let real = DocAccess.allowed(path, roots: DocAccess.roots(kbRoot: kbRoot)) {
                let size = (try? FileManager.default.attributesOfItem(atPath: real)[.size] as? Int) ?? 0
                if size > DocAccess.maxBytes {
                    msg = ["type": "doc", "id": id, "error": "too_large"]
                } else if let data = FileManager.default.contents(atPath: real) {
                    let url = URL(fileURLWithPath: real)
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    msg = ["type": "doc", "id": id, "name": url.lastPathComponent, "mime": mime,
                           "data": data.base64EncodedString()]
                } else {
                    msg = ["type": "doc", "id": id, "error": "not_found"]
                }
            } else {
                msg = ["type": "doc", "id": id, "error": "not_allowed"]
            }
            let json = Self.json(msg)
            DispatchQueue.main.async { MainActor.assumeIsolated { link.send(json) } }
        }
    }

    private func handle(_ text: String, from link: PhoneLink) {
        switch PhoneRequest.parse(text) {
        case .projects:
            link.send(projectsJSON())
            if let json = taskJSON(), preparer?.state != .idle { link.send(json) }
        case let .listDirs(id, path):
            listDirs(id: id, path: path, to: link)
        case let .addFolder(id, path):
            addFolder(id: id, path: path, to: link)
        case let .removeProject(id, project):
            phoneSearch.stop()   // een zoekproces van de telefoon kan dit project geladen hebben
            let error: String? = removeProject.map { $0(project) } ?? "failed"   // nil = gelukt
            Gateway.log("phone: remove project \(project) → \(error ?? "ok")")
            link.send(Self.json(["type": "project_removed", "id": id, "project": project, "ok": error == nil,
                                 "error": error ?? NSNull()]))
            projectsChanged()
        case let .getDoc(id, path):
            sendDoc(id: id, path: path, to: link)
        case .state:
            link.send(state().json())
        case let .start(requestID, projects, language, info):
            start(requestID: requestID, projects: projects, language: language, info: info, from: link)
        case .toHub(let raw):
            hub?.send(raw)
        case let .search(raw, id, query, projects):
            if let projects {   // startscherm: zelf zoeken, maar nooit een tweede KB naast een lopende meeting
                if backend.isRunning { phoneSearch.refuse(id, "busy") }
                else { phoneSearch.search(id: id, query: query, projects: projects) }
            } else if let hub {   // Find-tab van een meeting van de telefoon: in de KB die de pijplijn al geladen heeft
                hub.send(raw)
            } else {
                phoneSearch.refuse(id, "failed")
            }
        case .invalid:
            break
        }
    }

    private func start(requestID: String, projects: [String], language: String, info: String, from link: PhoneLink) {
        if seenRequests.contains(requestID) || backend.isRunning {   // al gestart, of iets anders draait
            link.send(state().json())
            return
        }
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
            seenRequests = Array((seenRequests + [requestID]).suffix(50))   // pas na een geslaagde start
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
        if backend.isRunning { phoneSearch.stop() }   // een meeting (ook een van de Mac) laadt de KB zelf: geen tweede kopie
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
