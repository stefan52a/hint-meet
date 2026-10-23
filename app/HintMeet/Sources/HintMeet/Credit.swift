import AppKit
import Combine
import SwiftUI

/// Hoeveel API-tegoed er nog is, geschat. Anthropic en Jev geven het tegoed niet via de API, dus: het bedrag dat
/// je in Settings invult (uit de Anthropic Console of het Jev-dashboard), min wat hint-meet sindsdien uitgaf.
/// Dat laatste telt de pijplijn per aanroep in usage.json (zie src/hint_meet/usage.py), voor alle HintMeets samen.
@MainActor
final class CreditTracker: ObservableObject {
    static let shared = CreditTracker()

    enum Service: String, CaseIterable, Identifiable {
        case anthropic, jev
        var id: String { rawValue }
        var name: String { self == .anthropic ? "Claude" : "Jev" }
    }

    /// Wat je invulde: het tegoed op dat moment, en de stand van de teller toen (alleen wat daarna komt telt).
    struct Entry: Codable, Equatable {
        var balance: Double
        var baseline: Double
        var date: Date
    }

    /// Totaal uitgegeven volgens usage.json, sinds het begin van het tellen.
    @Published private(set) var spent: [Service: Double] = [:]
    @Published private(set) var entries: [Service: Entry] = [:]

    static let ledgerURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/hint-meet/usage.json")
    private let d = UserDefaults.standard
    private var timer: AnyCancellable?

    private init() {
        for s in Service.allCases {
            if let data = d.data(forKey: key(s)), let e = try? JSONDecoder().decode(Entry.self, from: data) { entries[s] = e }
        }
        refresh()
        // goedkoop (een klein bestand): ook tijdens een meeting loopt het bedrag zo mee
        timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    }

    /// Niet per HintMeet (Instance): het tegoed hoort bij de sleutel, en die delen ze.
    private func key(_ s: Service) -> String { "credit.\(s.rawValue)" }

    func refresh() {
        guard let data = try? Data(contentsOf: Self.ledgerURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var now: [Service: Double] = [:]
        for s in Service.allCases { now[s] = ((json[s.rawValue] as? [String: Any])?["usd"] as? NSNumber)?.doubleValue ?? 0 }
        if now != spent { spent = now }
    }

    /// Je huidige tegoed invullen (nil = niet meer tonen).
    func set(_ s: Service, balance: Double?) {
        refresh()
        if let balance {
            let e = Entry(balance: balance, baseline: spent[s] ?? 0, date: Date())
            entries[s] = e
            d.set(try? JSONEncoder().encode(e), forKey: key(s))
        } else {
            entries[s] = nil
            d.removeObject(forKey: key(s))
        }
    }

    /// Uitgegeven sinds je het tegoed invulde.
    func used(_ s: Service) -> Double? {
        guard let e = entries[s] else { return nil }
        let total = spent[s] ?? 0
        // teller opnieuw begonnen (usage.json weg): alles wat hij nu telt is van na het invullen
        return total >= e.baseline ? total - e.baseline : total
    }

    func left(_ s: Service) -> Double? {
        guard let e = entries[s], let used = used(s) else { return nil }
        return e.balance - used
    }

    /// Bijna op: minder dan 10% van wat je invulde, of minder dan een dollar.
    func low(_ s: Service) -> Bool {
        guard let e = entries[s], let left = left(s) else { return false }
        return left < max(e.balance * 0.1, 1)
    }

    static func usd(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = abs(v) < 10 ? 2 : 0
        f.minimumFractionDigits = f.maximumFractionDigits
        return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }
}

/// Bovenin het paneel: "Claude ~$14.20 · Jev ~$3.10". Nog niets ingevuld: een knopje naar Settings.
struct CreditBadge: View {
    @ObservedObject var credit = CreditTracker.shared
    let openSettings: () -> Void

    var body: some View {
        let known = CreditTracker.Service.allCases.filter { credit.entries[$0] != nil }
        Button(action: openSettings) {
            if known.isEmpty {
                Label("Credit", systemImage: "creditcard").font(.caption)
            } else {
                HStack(spacing: 8) {
                    ForEach(known) { s in
                        Text("\(s.name) ~\(CreditTracker.usd(credit.left(s) ?? 0))")
                            .foregroundStyle(credit.low(s) ? Color.orange : Color.secondary)
                            .fontWeight(credit.low(s) ? .semibold : .regular)
                    }
                }
                .font(.caption).monospacedDigit()
            }
        }
        .buttonStyle(.borderless)
        .help(known.isEmpty
              ? "Show how much API credit is left: enter your current Claude and Jev credit in Settings"
              : known.map { s in
                    "\(s.name): \(CreditTracker.usd(credit.entries[s]!.balance)) on "
                        + credit.entries[s]!.date.formatted(date: .abbreviated, time: .omitted)
                        + ", HintMeet used \(CreditTracker.usd(credit.used(s) ?? 0)) since"
                }.joined(separator: "\n")
                + "\nAn estimate: only what HintMeet uses, not other apps with the same key. Click to update.")
    }
}

/// In Settings: per dienst je huidige tegoed invullen.
struct CreditSettings: View {
    @ObservedObject var credit = CreditTracker.shared
    @State private var input: [CreditTracker.Service: String] = [:]

    var body: some View {
        Section("Credit (estimate)") {
            Text("Anthropic and Jev don't report your credit to apps. Enter what you have now (Anthropic: Console → "
                 + "Billing; Jev: your TypeSafe dashboard); HintMeet subtracts what it uses from then on and shows "
                 + "what's left at the top of the panel. Other apps using the same key aren't counted, so enter "
                 + "it again now and then.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(CreditTracker.Service.allCases) { s in
                HStack {
                    TextField("\(s.name) credit now (USD)", text: Binding(get: { input[s] ?? "" }, set: { input[s] = $0 }))
                        .onSubmit { save(s) }
                    Button("Set") { save(s) }.disabled(amount(s) == nil)
                    if credit.entries[s] != nil {
                        Button("Clear") { credit.set(s, balance: nil); input[s] = "" }
                    }
                }
                if let e = credit.entries[s] {
                    Text("\(CreditTracker.usd(e.balance)) on \(e.date.formatted(date: .abbreviated, time: .shortened)) · "
                         + "used since: \(CreditTracker.usd(credit.used(s) ?? 0)) · "
                         + "left: ~\(CreditTracker.usd(credit.left(s) ?? 0))")
                        .font(.caption).foregroundStyle(credit.low(s) ? Color.orange : Color.secondary)
                }
            }
            Button("Open Anthropic Billing") {
                NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/billing")!)
            }
        }
    }

    /// "18,50", "$18.50" en "18.5" mogen alle drie.
    private func amount(_ s: CreditTracker.Service) -> Double? {
        let t = (input[s] ?? "").replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(t), v >= 0, v.isFinite else { return nil }
        return v
    }

    private func save(_ s: CreditTracker.Service) {
        guard let v = amount(s) else { return }
        credit.set(s, balance: v)
        input[s] = ""
    }
}
