// HintMeetWaker: draait als achtergronddienst (launchd, via SMAppService) zolang "Also when HintMeet is closed"
// aan staat. Draait HintMeet niet, dan luistert hij op het Tailscale-adres, poort 8790; klopt de telefoon aan, dan
// start hij HintMeet en gaat opzij. De telefoon verbindt na een paar seconden opnieuw, nu met de echte gateway.
// Er gaat hier niets over de lijn: de verbinding wordt meteen gesloten, geen sleutels, geen audio.
import AppKit
import Darwin
import HintMeetCore
import Network

let bundleID = "com.zoof-it.hintmeet"
let port: UInt16 = 8790
// dit programma zit in HintMeet.app en heeft dus dezelfde bundle-id: .standard zijn de instellingen van HintMeet
let defaults = UserDefaults.standard
let appURL = Bundle.main.bundleURL   // .../HintMeet.app (dit programma staat in Contents/MacOS)

var listener: NWListener?
var bound: String?
var quietUntil = Date.distantPast    // net HintMeet gestart: even niet opnieuw luisteren

/// ~/Library/Logs/HintMeet/waker.log, naast de andere logboeken van HintMeet.
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HintMeet/waker.log")

func log(_ s: String) {
    let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".utf8)
    try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { try? line.write(to: logURL) }
}

/// Draait HintMeet (dit app-bundel, of een andere kopie met dezelfde naam)? Rechtstreeks in de proceslijst
/// gekeken: NSRunningApplication wordt in een achtergrondproces zonder NSApplication niet betrouwbaar bijgewerkt.
func appRunning() -> Bool {
    var pids = [pid_t](repeating: 0, count: 4096)
    let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var path = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(max(0, n)) where pid > 0 && pid != getpid() {
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
        if String(cString: path).hasSuffix("HintMeet.app/Contents/MacOS/HintMeet") { return true }
    }
    return false
}

func wanted() -> Bool {
    defaults.bool(forKey: "phoneEnabled") && ((defaults.object(forKey: "phoneWake") as? Bool) ?? true)
}

func stopListening() {
    listener?.cancel()
    listener = nil
    bound = nil
}

func launchApp() {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.addsToRecentItems = false
    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
        if let error { log("starting HintMeet failed: \(error.localizedDescription)") }
    }
}

func listen(on address: String) {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!)
    params.allowLocalEndpointReuse = true
    guard let l = try? NWListener(using: params) else { return }
    l.newConnectionHandler = { conn in
        conn.cancel()   // niets uitwisselen
        guard case let .hostPort(host, _) = conn.endpoint else { return }
        var ip = "\(host)"
        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
        guard Tailnet.isTailnet(ip), !appRunning() else { return }
        log("phone knocked from \(ip): starting HintMeet")
        stopListening()                                  // de poort vrij voor de gateway van de app
        quietUntil = Date().addingTimeInterval(30)
        launchApp()
    }
    l.stateUpdateHandler = { state in
        if case .failed(let error) = state {
            log("couldn't listen on \(address):\(port): \(error.localizedDescription)")
            stopListening()
        }
    }
    l.start(queue: .main)
    listener = l
    bound = address
}

func tick() {
    let address = (wanted() && !appRunning() && Date() >= quietUntil) ? Tailnet.currentAddress() : nil
    if address != bound {
        stopListening()
        if let address { listen(on: address) }
    }
}

let timer = Timer(timeInterval: 2, repeats: true) { _ in tick() }
RunLoop.main.add(timer, forMode: .common)
tick()
RunLoop.main.run()
