import Foundation
import Security

// Pure hulpstukken voor de telefoon-gateway: geen sockets, geen UI. Zo zijn ze los te testen.

/// Het Tailscale-netwerk: adressen in 100.64.0.0/10 (CGNAT-blok dat Tailscale gebruikt).
public enum Tailnet {
    public static func octets(_ ipv4: String) -> [UInt8]? {
        let parts = ipv4.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    public static func isTailnet(_ ipv4: String) -> Bool {
        guard let o = octets(ipv4) else { return false }
        return o[0] == 100 && (o[1] & 0xC0) == 64    // 100.64.0.0 – 100.127.255.255
    }

    /// Het eerste Tailscale-adres uit de lijst met interfaces. Alleen op een utun-interface (daar zet Tailscale het):
    /// 100.64.0.0/10 is ook het CGNAT-blok van providers, en een mobiele hotspot geeft zo'n adres op en0.
    public static func address(from interfaces: [(name: String, ipv4: String)]) -> String? {
        interfaces.first { $0.name.hasPrefix("utun") && isTailnet($0.ipv4) }?.ipv4
    }

    /// Het Tailscale-adres van deze Mac op dit moment, of nil als Tailscale niet draait.
    public static func currentAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, ipv4: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: ptr.pointee.ifa_name), String(cString: host)))
        }
        return address(from: found)
    }

    /// MagicDNS-naam uit `tailscale status --json` (Self.DNSName, zonder punt aan het eind). Die naam blijft
    /// gelijk als het Tailscale-adres wisselt, dus de telefoon hoeft dan niet opnieuw te koppelen.
    public static func dnsName(fromStatusJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = obj["Self"] as? [String: Any],
              var name = me["DNSName"] as? String else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name
    }
}

public enum Pairing {
    /// Inhoud van de koppel-QR: hintmeet://pair?host=…&port=…&token=…
    public static func url(host: String, port: Int, token: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return "hintmeet://pair?host=\(enc(host))&port=\(port)&token=\(enc(token))"
    }
}

/// Wat de telefoon vraagt. stop, feedback, language en say gaan ongewijzigd door naar de hub van de pijplijn; search
/// tijdens een meeting van de telefoon ook (raw), anders zoekt de gateway zelf in `projects`.
public enum PhoneRequest: Equatable {
    case projects, state
    case start(requestID: String, projects: [String], language: String, info: String)
    case toHub(String)
    /// projects nil: uit de Find-tab van een meeting (zoekt in de KB van de meeting); anders het startscherm.
    case search(raw: String, id: String, query: String, projects: [String]?)
    /// Mappen op de Mac bekijken (path nil: de standaardmap) en er een als kennisbank toevoegen.
    case listDirs(id: String, path: String?)
    case addFolder(id: String, path: String)
    /// Een document (bron van een hint, Backed of Find) naar de telefoon halen.
    case getDoc(id: String, path: String)
    case invalid

    public static let hubTypes: Set<String> = ["stop", "feedback", "language", "say"]

    public static func parse(_ text: String) -> PhoneRequest {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return .invalid }
        switch type {
        case "projects": return .projects
        case "state": return .state
        case "start":
            guard let id = obj["request_id"] as? String, !id.isEmpty,
                  let projects = obj["projects"] as? [String], !projects.isEmpty else { return .invalid }
            return .start(requestID: id, projects: projects,
                          language: obj["language"] as? String ?? "nl", info: obj["info"] as? String ?? "")
        case "list_dirs":
            guard let id = requestID(obj) else { return .invalid }
            if let value = obj["path"], !(value is NSNull) {
                guard let path = value as? String, path.hasPrefix("/") else { return .invalid }
                return .listDirs(id: id, path: path)
            }
            return .listDirs(id: id, path: nil)
        case "add_folder":
            guard let id = requestID(obj), let path = obj["path"] as? String, path.hasPrefix("/") else { return .invalid }
            return .addFolder(id: id, path: path)
        case "get_doc":
            guard let id = requestID(obj), let path = obj["path"] as? String, path.hasPrefix("/") else { return .invalid }
            return .getDoc(id: id, path: path)
        case "search":
            guard let id = requestID(obj),
                  let query = (obj["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else { return .invalid }
            let projects: [String]?
            if let value = obj["projects"] {   // wel meegestuurd maar geen lijst met tekst: fout, niet negeren
                guard let list = value as? [String] else { return .invalid }
                projects = list
            } else { projects = nil }
            return .search(raw: text, id: id, query: query, projects: projects)
        default:
            return hubTypes.contains(type) ? .toHub(text) : .invalid
        }
    }

    /// Id van een verzoek van de telefoon: tekst, hooguit 80 tekens, zonder stuurtekens.
    private static func requestID(_ obj: [String: Any]) -> String? {
        guard let id = obj["id"] as? String, !id.isEmpty, id.count <= 80,
              id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return id
    }
}

/// Het `state`-bericht naar de telefoon. Lege velden gaan als null mee, zodat de telefoon ze niet hoeft te raden.
public struct GatewayState: Codable, Equatable {
    public struct Last: Codable, Equatable {
        public var meeting: String
        public var stoppedBy: String
        public var reportMD: String?

        public init(meeting: String, stoppedBy: String, reportMD: String?) {
            self.meeting = meeting; self.stoppedBy = stoppedBy; self.reportMD = reportMD
        }

        enum CodingKeys: String, CodingKey { case meeting, stoppedBy = "stopped_by", reportMD = "report_md" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            meeting = try c.decode(String.self, forKey: .meeting)
            stoppedBy = try c.decode(String.self, forKey: .stoppedBy)
            reportMD = try c.decodeIfPresent(String.self, forKey: .reportMD)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(meeting, forKey: .meeting)
            try c.encode(stoppedBy, forKey: .stoppedBy)
            if let reportMD { try c.encode(reportMD, forKey: .reportMD) } else { try c.encodeNil(forKey: .reportMD) }
        }
    }

    public var phase: String     // idle | starting | running | stopping
    public var meeting: String?
    public var startedAtMs: Int64?
    public var nowMs: Int64
    public var busyElsewhere: Bool
    public var last: Last?

    enum CodingKeys: String, CodingKey {
        case type, phase, meeting, startedAtMs = "started_at_ms", nowMs = "now_ms",
             busyElsewhere = "busy_elsewhere", last
    }

    public init(phase: String, meeting: String?, startedAtMs: Int64?, nowMs: Int64, busyElsewhere: Bool, last: Last?) {
        self.phase = phase; self.meeting = meeting; self.startedAtMs = startedAtMs
        self.nowMs = nowMs; self.busyElsewhere = busyElsewhere; self.last = last
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decode(String.self, forKey: .phase)
        meeting = try c.decodeIfPresent(String.self, forKey: .meeting)
        startedAtMs = try c.decodeIfPresent(Int64.self, forKey: .startedAtMs)
        nowMs = try c.decode(Int64.self, forKey: .nowMs)
        busyElsewhere = try c.decode(Bool.self, forKey: .busyElsewhere)
        last = try c.decodeIfPresent(Last.self, forKey: .last)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("state", forKey: .type)
        try c.encode(phase, forKey: .phase)
        if let meeting { try c.encode(meeting, forKey: .meeting) } else { try c.encodeNil(forKey: .meeting) }
        if let startedAtMs { try c.encode(startedAtMs, forKey: .startedAtMs) } else { try c.encodeNil(forKey: .startedAtMs) }
        try c.encode(nowMs, forKey: .nowMs)
        try c.encode(busyElsewhere, forKey: .busyElsewhere)
        if let last { try c.encode(last, forKey: .last) } else { try c.encodeNil(forKey: .last) }
    }

    public func json() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return #"{"type":"state","phase":"idle"}"# }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum LastResult {
    /// De nieuwste `live-*.meta.json` van deze telefoon-meeting, met het verslag erbij als dat er al is.
    /// Zonder `stopped_by` is de pijplijn niet netjes geëindigd (crash, Mac sliep): dan nil, zodat de
    /// telefoon "Mac stopped unexpectedly" meldt.
    public static func read(logs: URL, meeting: String) -> GatewayState.Last? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []
        let metas = names.filter { $0.hasPrefix("live-") && $0.hasSuffix(".meta.json") }.sorted(by: >)
        for name in metas {   // de naam bevat datum en tijd: nieuwste eerst
            guard let data = try? Data(contentsOf: logs.appendingPathComponent(name)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["phone_meeting"] as? String == meeting else { continue }
            guard let stoppedBy = obj["stopped_by"] as? String else { return nil }
            let report = (obj["report"] as? String).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            return .init(meeting: meeting, stoppedBy: stoppedBy, reportMD: report)
        }
        return nil
    }
}

/// Nieuwe meeting-id voor de telefoon: 16 hex-tekens (een uint64 in het audioframe).
public func meetingID() -> String {
    var bytes = [UInt8](repeating: 0, count: 8)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
        bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Op welk adres de gateway moet luisteren (elke 5 s gevraagd): het Tailscale-adres kan wisselen of verdwijnen.
public struct TailnetMonitor {
    public enum Action: Equatable { case none, bind(String), unbind }

    public init() {}

    public mutating func decide(current: String?, bound: String?) -> Action {
        switch (current, bound) {
        case (nil, nil): return .none
        case (nil, _?): return .unbind
        case let (c?, b): return c == b ? .none : .bind(c)
        }
    }
}

/// Telefoon-sleutel in de koptekst `Authorization: Bearer <token>` (Network.framework geeft het pad van het
/// verzoek niet door, dus ?token= kan niet). Tijdsconstant vergelijken.
public enum PhoneAuth {
    public static func authorized(headers: [(name: String, value: String)], token: String) -> Bool {
        guard !token.isEmpty,
              let value = headers.first(where: { $0.name.lowercased() == "authorization" })?.value,
              value.hasPrefix("Bearer ") else { return false }
        return constantTimeEqual(String(value.dropFirst(7)), token)
    }

    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    /// Nieuwe telefoon-sleutel: 32 willekeurige bytes, base64url zonder opvulling.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Regels van `hint-meet search --serve` tijdens het laden.
public enum SearchServe {
    /// De tekst uit "@step <sleutel> <tekst>", "@progress <klaar> <totaal> <tekst>" of "@note <tekst>"; anders nil.
    public static func progressText(_ line: String) -> String? {
        let fields: Int
        if line.hasPrefix("@step ") { fields = 3 }
        else if line.hasPrefix("@progress ") { fields = 4 }
        else if line.hasPrefix("@note ") { fields = 2 }
        else { return nil }
        let parts = line.split(separator: " ", maxSplits: fields - 1)
        guard parts.count == fields else { return nil }
        let text = parts[fields - 1].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

/// Mappen op deze Mac kiezen vanaf de telefoon ("Add Folder"): alleen mappen, alleen binnen de thuismap, geen
/// verborgen mappen of pakketten (.app e.d.). Bestandsnamen gaan nooit naar de telefoon.
public enum FolderBrowser {
    public struct Listing: Equatable {
        public var path: String
        public var parent: String?
        public var dirs: [String]
    }

    /// Standaard: ~/projects als die bestaat, anders de thuismap.
    public static func defaultPath(home: String) -> String {
        var isDir: ObjCBool = false
        let projects = home + "/projects"
        return FileManager.default.fileExists(atPath: projects, isDirectory: &isDir) && isDir.boolValue ? projects : home
    }

    /// Het pad zoals het echt is (symlinks opgelost), of nil als het geen map binnen `home` is.
    public static func resolve(_ path: String, home: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard real == root || real.hasPrefix(root + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { return nil }
        return real
    }

    public static func list(_ path: String, home: String) -> Listing? {
        guard let real = resolve(path, home: home) else { return nil }
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        let url = URL(fileURLWithPath: real)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let dirs = items.compactMap { item -> String? in
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isDirectory == true,
                  v.isPackage != true, v.isHidden != true else { return nil }
            return item.lastPathComponent
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let parent = real == root ? nil : url.deletingLastPathComponent().path
        return Listing(path: real, parent: parent, dirs: dirs)
    }
}

/// Welke documenten de telefoon mag ophalen: alleen bestanden in de kennisbankmap of in een bronmap van een
/// kennisbank (source_root uit kb_prep's manifest). Nooit iets anders op de Mac.
public enum DocAccess {
    public static let maxBytes = 12 * 1024 * 1024

    /// Het echte pad (symlinks opgelost) als het een bestand binnen een van de `roots` is, anders nil.
    public static func allowed(_ path: String, roots: [String]) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), !isDir.boolValue else { return nil }
        for root in roots where !root.isEmpty {
            let r = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            if r != "/" && real.hasPrefix(r + "/") { return real }
        }
        return nil
    }

    /// kbRoot plus de source_root van elk project met een manifest.
    public static func roots(kbRoot: String) -> [String] {
        var out = [kbRoot]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: kbRoot)) ?? []
        for name in names where !name.hasPrefix(".") {
            let manifest = URL(fileURLWithPath: kbRoot).appendingPathComponent(name).appendingPathComponent("_manifest.json")
            if let data = try? Data(contentsOf: manifest),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let root = json["source_root"] as? String { out.append(root) }
        }
        return out
    }
}
