// Controles op HintMeetCore: `swift run GatewayChecks` (exit 1 bij een fout).
// Zelfgebouwd omdat `swift test` met alleen de Command Line Tools niets uitvoert; met Xcode kan dit naar XCTest.
import Foundation
import HintMeetCore

var failures = 0
var current = ""

func check(_ ok: @autoclosure () -> Bool, _ what: String = "", line: Int = #line) {
    if !ok() {
        failures += 1
        print("✘ \(current): regel \(line) \(what)")
    }
}

func section(_ name: String, _ body: () throws -> Void) {
    current = name
    let before = failures
    do { try body() } catch { failures += 1; print("✘ \(name): \(error)") }
    if failures == before { print("✔ \(name)") }
}

func object(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
}

section("tailnet range") {
    check(Tailnet.isTailnet("100.64.0.1"))
    check(Tailnet.isTailnet("100.127.255.254"))
    check(!Tailnet.isTailnet("100.128.0.1"))
    check(!Tailnet.isTailnet("100.63.255.255"))
    check(!Tailnet.isTailnet("192.168.1.5"))
    check(!Tailnet.isTailnet("100.64.0"))
    check(!Tailnet.isTailnet("100.64.0.256"))
    check(Tailnet.address(from: [("en0", "192.168.1.5"), ("utun4", "100.101.102.103")]) == "100.101.102.103")
    check(Tailnet.address(from: [("en0", "192.168.1.5")]) == nil)
    check(Tailnet.address(from: [("en0", "100.70.1.2")]) == nil, "CGNAT van een hotspot is geen Tailscale")
}

section("pairing URL encodes token") {
    check(Pairing.url(host: "100.1.2.3", port: 8790, token: "a+b/c")
          == "hintmeet://pair?host=100.1.2.3&port=8790&token=a%2Bb%2Fc")
    check(Pairing.url(host: "mac.tail1234.ts.net", port: 8790, token: "x=y&z")
          == "hintmeet://pair?host=mac.tail1234.ts.net&port=8790&token=x%3Dy%26z")
}

section("MagicDNS name from tailscale status") {
    let json = #"{"Self":{"DNSName":"macbook.tail1234.ts.net.","TailscaleIPs":["100.1.2.3"]}}"#
    check(Tailnet.dnsName(fromStatusJSON: Data(json.utf8)) == "macbook.tail1234.ts.net")
    check(Tailnet.dnsName(fromStatusJSON: Data(#"{"Self":{"DNSName":""}}"#.utf8)) == nil)
    check(Tailnet.dnsName(fromStatusJSON: Data("nope".utf8)) == nil)
}

section("routing") {
    check(PhoneRequest.parse(#"{"type":"projects"}"#) == .projects)
    check(PhoneRequest.parse(#"{"type":"state"}"#) == .state)
    check(PhoneRequest.parse(#"{"type":"stop","final_offset":5}"#) == .toHub(#"{"type":"stop","final_offset":5}"#))
    check(PhoneRequest.parse(#"{"type":"feedback","id":3,"rating":1}"#) == .toHub(#"{"type":"feedback","id":3,"rating":1}"#))
    check(PhoneRequest.parse(#"{"type":"start","request_id":"r1","projects":["acme"],"language":"nl","info":""}"#)
          == .start(requestID: "r1", projects: ["acme"], language: "nl", info: ""))
    check(PhoneRequest.parse(#"{"type":"start","projects":["acme"]}"#) == .invalid, "start zonder request_id")
    check(PhoneRequest.parse(#"{"type":"say","text":"hallo"}"#) == .toHub(#"{"type":"say","text":"hallo"}"#))
    let find = #"{"type":"search","id":"phone-1","query":" lening ","projects":["acme"]}"#
    check(PhoneRequest.parse(find) == .search(raw: find, id: "phone-1", query: "lening", projects: ["acme"]))
    check(PhoneRequest.parse(#"{"type":"search","id":"p","query":"x"}"#)
          == .search(raw: #"{"type":"search","id":"p","query":"x"}"#, id: "p", query: "x", projects: nil))
    check(PhoneRequest.parse(#"{"type":"search","id":"p","query":"x","projects":["a",1]}"#) == .invalid, "projects met een getal")
    check(PhoneRequest.parse(#"{"type":"search","id":"p","query":"x","projects":"a"}"#) == .invalid)
    check(PhoneRequest.parse(#"{"type":"search","id":3,"query":"x"}"#) == .invalid, "id moet tekst zijn")
    check(PhoneRequest.parse(#"{"type":"search","id":"p","query":"  "}"#) == .invalid)
    check(PhoneRequest.parse(#"{"type":"search","id":"p\n@ready","query":"x"}"#) == .invalid, "geen regeleinde in de id")
    check(PhoneRequest.parse("not json") == .invalid)
    check(PhoneRequest.parse(#"{"type":"shutdown"}"#) == .invalid)
}

section("state JSON has explicit nulls") {
    let s = GatewayState(phase: "idle", meeting: nil, startedAtMs: nil, nowMs: 42, busyElsewhere: false, last: nil)
    let obj = object(s.json())
    check(obj["type"] as? String == "state")
    check(obj["now_ms"] as? Int == 42)
    check(obj["busy_elsewhere"] as? Bool == false)
    check(obj.keys.contains("meeting") && obj["meeting"] is NSNull)
    check(obj["last"] is NSNull && obj["started_at_ms"] is NSNull)
    let full = GatewayState(phase: "running", meeting: "00000000000000aa", startedAtMs: 1_000, nowMs: 2_000,
                            busyElsewhere: false,
                            last: .init(meeting: "00000000000000ab", stoppedBy: "watchdog", reportMD: nil))
    let last = object(full.json())["last"] as? [String: Any] ?? [:]
    check(last["stopped_by"] as? String == "watchdog" && last["report_md"] is NSNull)
    check((try? JSONDecoder().decode(GatewayState.self, from: Data(full.json().utf8))) == full, "roundtrip")
}

section("last result finds report for meeting") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let report = dir.appendingPathComponent("verslag.md")
    try "# Verslag\nPunt 1".write(to: report, atomically: true, encoding: .utf8)
    func meta(_ name: String, _ obj: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent(name))
    }
    try meta("live-20261103-100000.meta.json", ["phone_meeting": "00000000000000aa", "stopped_by": "user"])
    try meta("live-20261103-110000.meta.json", ["phone_meeting": "00000000000000bb", "stopped_by": "watchdog",
                                                 "report": report.path])
    try meta("live-20261103-120000.meta.json", ["project": "x"])          // gewone meeting zonder telefoon
    let last = LastResult.read(logs: dir, meeting: "00000000000000bb")
    check(last?.meeting == "00000000000000bb" && last?.stoppedBy == "watchdog")
    check(last?.reportMD == "# Verslag\nPunt 1")
    check(LastResult.read(logs: dir, meeting: "00000000000000aa") != nil)
    check(LastResult.read(logs: dir, meeting: "00000000000000aa")?.reportMD == nil)
    check(LastResult.read(logs: dir, meeting: "00000000000000cc") == nil)
    try meta("live-20261103-130000.meta.json", ["phone_meeting": "00000000000000dd"])   // gecrasht: geen stopped_by
    check(LastResult.read(logs: dir, meeting: "00000000000000dd") == nil, "crash geeft geen resultaat")
}

section("meeting ID is 16 hex") {
    let a = meetingID(), b = meetingID()
    check(a.count == 16 && a.allSatisfy { "0123456789abcdef".contains($0) })
    check(a != b)
}

section("tailnet monitor rebinds on change") {
    var m = TailnetMonitor()
    check(m.decide(current: "100.1.1.1", bound: nil) == .bind("100.1.1.1"))
    check(m.decide(current: "100.1.1.1", bound: "100.1.1.1") == .none)
    check(m.decide(current: "100.2.2.2", bound: "100.1.1.1") == .bind("100.2.2.2"))
    check(m.decide(current: nil, bound: "100.2.2.2") == .unbind)
    check(m.decide(current: nil, bound: nil) == .none)
}

section("phone auth header") {
    let t = "abc123"
    check(PhoneAuth.authorized(headers: [("Authorization", "Bearer abc123")], token: t))
    check(PhoneAuth.authorized(headers: [("authorization", "Bearer abc123")], token: t))
    check(!PhoneAuth.authorized(headers: [("Authorization", "Bearer abc124")], token: t))
    check(!PhoneAuth.authorized(headers: [("Authorization", "Bearer abc12")], token: t))
    check(!PhoneAuth.authorized(headers: [("Authorization", "abc123")], token: t))
    check(!PhoneAuth.authorized(headers: [], token: t))
    check(!PhoneAuth.authorized(headers: [("Authorization", "Bearer ")], token: ""), "lege sleutel nooit goed")
    let n = PhoneAuth.newToken()
    check(n.count >= 43 && !n.contains("+") && !n.contains("/") && !n.contains("="))
}

section("search --serve progress lines") {
    check(SearchServe.progressText("@step model Loading embedding model") == "Loading embedding model")
    check(SearchServe.progressText("@progress 10 200 Embeddings: 10 of 200 new chunks · ~3 min left")
          == "Embeddings: 10 of 200 new chunks · ~3 min left")
    check(SearchServe.progressText("@note The first time takes about 20 minutes") == "The first time takes about 20 minutes")
    check(SearchServe.progressText("@ready 120") == nil)
    check(SearchServe.progressText("@results {}") == nil)
    check(SearchServe.progressText("@step model") == nil)
    check(SearchServe.progressText("@plan [[\"a\",\"b\"]]") == nil)
}

section("folders from the phone") {
    check(PhoneRequest.parse(#"{"type":"list_dirs","id":"d1"}"#) == .listDirs(id: "d1", path: nil))
    check(PhoneRequest.parse(#"{"type":"list_dirs","id":"d1","path":null}"#) == .listDirs(id: "d1", path: nil))
    check(PhoneRequest.parse(#"{"type":"list_dirs","id":"d1","path":"/Users/x"}"#) == .listDirs(id: "d1", path: "/Users/x"))
    check(PhoneRequest.parse(#"{"type":"list_dirs","id":"d1","path":"projects"}"#) == .invalid, "relatief pad")
    check(PhoneRequest.parse(#"{"type":"list_dirs","id":"d1","path":3}"#) == .invalid)
    check(PhoneRequest.parse(#"{"type":"list_dirs"}"#) == .invalid, "zonder id")
    check(PhoneRequest.parse(#"{"type":"add_folder","id":"a1","path":"/Users/x/p"}"#) == .addFolder(id: "a1", path: "/Users/x/p"))
    check(PhoneRequest.parse(#"{"type":"add_folder","id":"a1"}"#) == .invalid)
    check(PhoneRequest.parse(#"{"type":"add_folder","id":"a\nb","path":"/x"}"#) == .invalid)

    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("hm-folders-\(UUID().uuidString)").resolvingSymlinksInPath().path
    defer { try? fm.removeItem(atPath: home) }
    for d in ["projects/b", "projects/A", "projects/.hidden", "projects/Tool.app", "other"] {
        try? fm.createDirectory(atPath: home + "/" + d, withIntermediateDirectories: true)
    }
    fm.createFile(atPath: home + "/projects/file.txt", contents: Data())
    try? fm.createSymbolicLink(atPath: home + "/projects/out", withDestinationPath: "/tmp")
    check(FolderBrowser.defaultPath(home: home) == home + "/projects")
    check(FolderBrowser.defaultPath(home: home + "/other") == home + "/other", "zonder projects: thuismap")
    let l = FolderBrowser.list(home + "/projects", home: home)
    check(l?.dirs == ["A", "b"], "alleen gewone mappen, gesorteerd: \(l?.dirs ?? [])")
    check(l?.parent == home)
    check(FolderBrowser.list(home, home: home)?.parent == nil, "niet boven de thuismap")
    check(FolderBrowser.list("/tmp", home: home) == nil, "buiten de thuismap")
    check(FolderBrowser.list(home + "/projects/out", home: home) == nil, "symlink naar buiten")
    check(FolderBrowser.list(home + "/projects/../..", home: home) == nil, "..")
    check(FolderBrowser.list(home + "/projects/file.txt", home: home) == nil, "bestand")
    check(FolderBrowser.resolve(home + "/projects/A/", home: home) == home + "/projects/A")
}

section("documents for the phone") {
    check(PhoneRequest.parse(#"{"type":"get_doc","id":"g1","path":"/a/b.pdf"}"#) == .getDoc(id: "g1", path: "/a/b.pdf"))
    check(PhoneRequest.parse(#"{"type":"get_doc","id":"g1","path":"b.pdf"}"#) == .invalid)
    check(PhoneRequest.parse(#"{"type":"get_doc","id":"g1"}"#) == .invalid)
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("hm-docs-\(UUID().uuidString)").resolvingSymlinksInPath().path
    defer { try? fm.removeItem(atPath: base) }
    let kb = base + "/KB_md", src = base + "/sources/Acme", other = base + "/private"
    for d in [kb + "/acme", src + "/sub", other] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
    let manifest = try! JSONSerialization.data(withJSONObject: ["source_root": src])
    fm.createFile(atPath: kb + "/acme/_manifest.json", contents: manifest)
    fm.createFile(atPath: kb + "/acme/note.md", contents: Data("x".utf8))
    fm.createFile(atPath: src + "/sub/offer.pdf", contents: Data("x".utf8))
    fm.createFile(atPath: other + "/secret.txt", contents: Data("x".utf8))
    try? fm.createSymbolicLink(atPath: src + "/link.txt", withDestinationPath: other + "/secret.txt")
    let roots = DocAccess.roots(kbRoot: kb)
    check(roots.contains(src), "bronmap uit het manifest")
    check(DocAccess.allowed(kb + "/acme/note.md", roots: roots) == kb + "/acme/note.md")
    check(DocAccess.allowed(src + "/sub/offer.pdf", roots: roots) == src + "/sub/offer.pdf")
    check(DocAccess.allowed(other + "/secret.txt", roots: roots) == nil, "buiten de kennisbanken")
    check(DocAccess.allowed(src + "/link.txt", roots: roots) == nil, "symlink naar buiten")
    check(DocAccess.allowed(src + "/sub/../../../private/secret.txt", roots: roots) == nil, "..")
    check(DocAccess.allowed(src + "/sub", roots: roots) == nil, "map")
    check(DocAccess.allowed(kb + "/acme/nope.md", roots: roots) == nil, "bestaat niet")
}

print(failures == 0 ? "\nAlle controles geslaagd" : "\n\(failures) controle(s) mislukt")
exit(failures == 0 ? 0 : 1)
