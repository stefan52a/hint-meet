import AppKit
import Combine
import SwiftUI

/// De drie kolommen van een meeting. Elke kolom kan los in een eigen venster (verplaatsen, vergroten);
/// dat venster sluiten zet hem terug in het paneel.
enum MeetingColumn: String, CaseIterable, Identifiable {
    case backed, transcript, hints
    var id: String { rawValue }

    var title: String {
        switch self {
        case .backed: return "Backed by the KB"
        case .transcript: return "Transcript"
        case .hints: return "Hints & corrections"
        }
    }

    var icon: String {
        switch self {
        case .backed: return "checkmark.seal"
        case .transcript: return "text.bubble"
        case .hints: return "lightbulb"
        }
    }

    /// Deel van de breedte in het paneel als alle drie erin staan.
    var share: CGFloat {
        switch self {
        case .backed: return 0.27
        case .transcript: return 0.34
        case .hints: return 0.39
        }
    }
}

/// Welke kolommen in een eigen venster staan; onthouden tussen starts.
@MainActor
final class ColumnDock: ObservableObject {
    @Published private(set) var undocked: Set<MeetingColumn>
    private let key = Instance.key("undockedColumns")

    init() {
        undocked = Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(MeetingColumn.init))
    }

    func undock(_ c: MeetingColumn) { undocked.insert(c); save() }
    func dock(_ c: MeetingColumn) { undocked.remove(c); save() }
    func dockAll() { undocked = []; save() }

    private func save() { UserDefaults.standard.set(undocked.map(\.rawValue).sorted(), forKey: key) }
}

/// Eén kolom met zijn kop: titel, aantal, (los)koppelen en eventueel het gevoeligheidsschuifje.
/// Dezelfde view staat in het paneel en in een los venster.
struct MeetingColumnView: View {
    let column: MeetingColumn
    @ObservedObject var store: HintStore
    @ObservedObject var settings: Settings
    @ObservedObject var dock: ColumnDock
    let send: ([String: Any]) -> Void
    /// Laat het regeltje over een ingetrokken hint na een paar seconden verdwijnen, ook in een los venster.
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var undocked: Bool { dock.undocked.contains(column) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch column {
            case .backed: ConfirmList(store: store)
            case .transcript: transcript
            case .hints: hints
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(timer) { if column == .hints { tick = $0 } }
    }

    private var count: Int {
        switch column {
        case .backed: return store.confirmations.count
        case .transcript: return store.transcript.count
        case .hints: return store.history.count
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(column.title, systemImage: column.icon).font(.subheadline.weight(.semibold))
                if count > 0 {
                    Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer(minLength: 0)
                Button { undocked ? dock.dock(column) : dock.undock(column) } label: {
                    Image(systemName: undocked ? "rectangle.portrait.and.arrow.forward" : "macwindow.badge.plus")
                }
                .buttonStyle(.borderless)
                .help(undocked ? "Put this column back in the HintMeet panel" : "Open this column in its own window")
            }
            switch column {
            case .backed:
                SensitivitySlider(title: "", value: $settings.confirmSensitivity,
                                  help: "More: also less clearly matching passages and shorter utterances. Fewer: only "
                                      + "clear matches. A ✓ always means nothing in the utterance contradicts the documents.",
                                  changed: sendSensitivity)
            case .hints:
                SensitivitySlider(title: "", value: $settings.hintSensitivity,
                                  help: "More: hints and corrections also when the gatekeeper is less sure and on less "
                                      + "clearly matching passages. Fewer: only when it clearly matters.",
                                  changed: sendSensitivity)
            case .transcript:
                EmptyView()
            }
        }
    }

    private func sendSensitivity() { send(settings.sensitivityMessage) }

    @ViewBuilder private var transcript: some View {
        if store.transcript.isEmpty {
            placeholder("What is said appears here.")
        } else {
            TranscriptView(store: store)
        }
    }

    /// Bladeren en de hints op volgorde, en intrekkingen.
    @ViewBuilder private var hints: some View {
        if store.listHints.isEmpty {
            placeholder("Answers and corrections from your documents appear here when they matter.")
        } else {
            if store.history.count > 1 || store.isBrowsing { historyBar }
            HintsList(store: store, rate: { id, r in
                store.rate(id, r)
                send(["type": "feedback", "id": id, "rating": r, "session": store.session])
            })
            .frame(maxHeight: .infinity)
        }
        if let r = store.justRetracted, !store.isBrowsing {
            // bewust klein en grijs: wat niet meer klopt hoort niet de aandacht te trekken
            Text("Retracted (\(r.reason)): \(r.text)")
                .font(.caption).strikethrough().foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Terugbladeren door de hints van deze meeting; nieuwe hints komen binnen zonder je plek te verliezen.
    private var historyBar: some View {
        let history = store.history
        let index = store.shownIndex ?? max(history.count - 1, 0)
        return HStack(spacing: 6) {
            Button { store.back() } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0 && store.isBrowsing)
                .help("Previous hint (⌘[)")
            Text("Hint \(min(index + 1, history.count)) of \(history.count)"
                 + (store.shown.map { " · " + OverlayView.clock.string(from: $0.updated) } ?? ""))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button { store.forward() } label: { Image(systemName: "chevron.right") }
                .disabled(!store.isBrowsing)
                .help("Next hint (⌘])")
            Spacer()
            if store.isBrowsing {
                let newer = history.count - 1 - index
                Button(newer > 0 ? "Latest (\(newer) newer)" : "Latest") { store.latest() }
                    .controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
    }
}

/// Inhoud van een los kolomvenster: de kolom met wat ruimte eromheen.
struct ColumnWindowView: View {
    let column: MeetingColumn
    @ObservedObject var store: HintStore
    @ObservedObject var settings: Settings
    @ObservedObject var dock: ColumnDock
    let send: ([String: Any]) -> Void

    var body: some View {
        MeetingColumnView(column: column, store: store, settings: settings, dock: dock, send: send)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }
}
