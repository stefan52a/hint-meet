import Combine
import Foundation

/// Eén hint zoals de pijplijn hem meldt: in wording, definitief (met bronnen) of ingetrokken.
struct Hint: Identifiable, Equatable {
    enum State: String { case streaming, final, retracted }
    struct Source: Equatable, Hashable { let ref: String; let path: String }

    let id: Int
    var state: State
    var text: String
    var sources: [Source] = []
    var reason: String = ""
    var rating: Int = 0
    var updated = Date()
}

struct Utterance: Identifiable, Equatable {
    let id: Int
    let time: String
    let speaker: String
    let text: String
}

/// Houdt de stand bij op basis van berichten van de lokale server (zie src/hint_meet/server.py).
@MainActor
final class HintStore: ObservableObject {
    @Published var connected = false
    @Published var project = ""
    @Published var hints: [Hint] = []           // nieuwste laatst
    @Published var utterances: [Utterance] = []  // laatste paar
    @Published var summaryPath: String?
    @Published var stopped = false
    @Published var status = ""      // wat de pijplijn aan het doen is (KB laden, luistert…)
    /// Terugbladeren: id van de hint die je bekijkt (niet zijn plaats: nieuwe of ingetrokken hints
    /// verschuiven de lijst); nil = altijd de nieuwste hint.
    @Published var browseID: Int?
    /// Uitspraak waarop een hint reageert (hint-id = id van de uitspraak), voor de geschiedenis.
    private(set) var spoken: [Int: Utterance] = [:]
    /// Het hele transcript van deze meeting, op volgorde, voor de scrollbare kolom in het paneel.
    @Published private(set) var transcript: [Utterance] = []
    private(set) var session = ""

    /// Alle definitieve hints van deze meeting, oudste eerst: de geschiedenis om door te bladeren.
    var history: [Hint] { hints.filter { $0.state == .final }.sorted { $0.id < $1.id } }

    /// Wat de hoofdplek toont: de hint waar je naartoe hebt gebladerd, anders de nieuwste.
    var shown: Hint? {
        if let id = browseID, let h = history.first(where: { $0.id == id }) { return h }
        return current
    }

    var isBrowsing: Bool { browseID != nil && history.contains { $0.id == browseID } }

    /// Plaats van de getoonde hint in `history` (voor "Hint 3 of 12").
    var shownIndex: Int? { history.firstIndex { $0.id == shown?.id } }

    /// Wie de selectie het laatst veranderde: die lijst scrollt niet nog eens mee (anders zingt het rond).
    enum SelectionSource { case transcript, hints, other }
    var selectionSource: SelectionSource = .other
    /// Telt op bij elke keuze van jou (klik, ◀ ▶, Latest): beide lijsten scrollen dan naar de gekozen hint
    /// en zijn uitspraak, ook als het de nieuwste is of al geselecteerd was.
    @Published private(set) var revealToken = 0

    /// Lijst rechts: alle definitieve hints op volgorde, plus een hint die nog binnenkomt.
    var listHints: [Hint] {
        var list = history
        if let c = current, c.state == .streaming, !list.contains(where: { $0.id == c.id }) { list.append(c) }
        return list
    }

    func back() {
        selectionSource = .other
        defer { revealToken += 1 }
        let h = history
        guard !h.isEmpty else { return }
        let i = isBrowsing ? (shownIndex ?? 0) : (h.lastIndex { $0.id == current?.id } ?? h.count)
        browseID = h[max(i - 1, 0)].id
    }

    func forward() {
        selectionSource = .other
        defer { revealToken += 1 }
        let h = history
        guard isBrowsing, let i = shownIndex else { return }
        browseID = i + 1 >= h.count ? nil : h[i + 1].id   // voorbij de laatste: weer live
    }

    func latest(from source: SelectionSource = .other) {
        selectionSource = source
        browseID = nil
        if source == .other { revealToken += 1 }
    }

    /// Klik op een uitspraak in het transcript: de hint die erop reageerde tonen (als die er is).
    func browse(to utteranceID: Int, from source: SelectionSource = .other) {
        guard history.contains(where: { $0.id == utteranceID }) else { return }
        selectionSource = source
        defer { if source == .other { revealToken += 1 } }
        browseID = utteranceID == current?.id ? nil : utteranceID
    }

    /// Klik op een willekeurige uitspraak: zijn eigen hint, anders de hint die toen in beeld was (de laatste
    /// ervoor), anders de eerstvolgende. Het transcript markeert dan de uitspraak van die hint.
    func focus(onUtterance id: Int) {
        let h = history
        guard let hint = h.first(where: { $0.id == id }) ?? h.last(where: { $0.id < id }) ?? h.first(where: { $0.id > id })
        else { return }
        browse(to: hint.id, from: .other)
    }

    /// Uitspraken waarop een (definitieve) hint reageerde: die krijgen een 💡 in het transcript.
    var hinted: Set<Int> { Set(history.map(\.id)) }

    /// De hint die je kunt gebruiken; ingetrokken hints krijgen nooit de hoofdplek.
    var current: Hint? { hints.last { $0.state != .retracted } }
    /// Net ingetrokken (na de huidige hint): een paar seconden als klein regeltje, zodat je weet waarom hij weg is.
    var justRetracted: Hint? {
        guard let last = hints.last, last.state == .retracted, Date().timeIntervalSince(last.updated) < 6 else { return nil }
        return last
    }
    var earlier: [Hint] {
        guard let cur = current else { return Array(hints.filter { $0.state == .final }.suffix(3)) }
        return Array(hints.filter { $0.state == .final && $0.id != cur.id }.suffix(3))
    }

    func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "hello":
            // nieuwe sessie: niets van een vorige meeting meenemen (id's beginnen weer bij 0)
            let new = msg["session"] as? String ?? ""
            if new != session {
                hints = []; utterances = []; summaryPath = nil; status = ""; spoken = [:]; transcript = []; browseID = nil
                session = new
            }
            project = msg["project"] as? String ?? ""
            stopped = false
        case "utterance":
            guard let id = msg["id"] as? Int else { return }
            let u = Utterance(id: id, time: msg["time"] as? String ?? "",
                              speaker: msg["speaker"] as? String ?? "", text: msg["text"] as? String ?? "")
            utterances.removeAll { $0.id == id }
            utterances.append(u)
            spoken[id] = u
            if let i = transcript.lastIndex(where: { $0.id == id }) {
                transcript[i] = u   // zelfde uitspraak opnieuw (bijgewerkt): vervangen
            } else {
                transcript.append(u)
                if let last = transcript.dropLast().last, last.id > id {   // te laat binnen: op zijn plek
                    transcript.sort { $0.id < $1.id }
                }
            }
            utterances = Array(utterances.suffix(4))
        case "hint":
            guard let id = msg["id"] as? Int, let state = Hint.State(rawValue: msg["state"] as? String ?? "") else { return }
            var hint = hints.first { $0.id == id } ?? Hint(id: id, state: state, text: "")
            hint.state = state
            hint.text = msg["text"] as? String ?? hint.text
            hint.reason = msg["reason"] as? String ?? ""
            if let srcs = msg["sources"] as? [[String: Any]] {
                hint.sources = srcs.map { Hint.Source(ref: $0["ref"] as? String ?? "", path: $0["path"] as? String ?? "") }
            }
            hint.updated = Date()
            hints.removeAll { $0.id == id }
            hints.append(hint)
            hints = Array(hints.suffix(500))   // ruim genoeg voor een lange meeting, om terug te bladeren
        case "status":
            status = msg["text"] as? String ?? ""
        case "summary":
            summaryPath = msg["path"] as? String
        case "stopped":
            stopped = true
        default:
            break
        }
    }

    func rate(_ id: Int, _ rating: Int) {
        if let i = hints.firstIndex(where: { $0.id == id }) { hints[i].rating = rating }
    }
}
