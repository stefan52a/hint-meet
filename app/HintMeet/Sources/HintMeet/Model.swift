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
    private(set) var session = ""

    var current: Hint? { hints.last { $0.state != .retracted || Date().timeIntervalSince($0.updated) < 4 } }
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
                hints = []; utterances = []; summaryPath = nil; status = ""
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
            hints = Array(hints.suffix(20))
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
