import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var store: HintStore
    @ObservedObject var backend: Backend
    @ObservedObject var preparer: ProgressTask
    @ObservedObject var settings: Settings
    @ObservedObject var layout: PanelLayout
    let send: ([String: Any]) -> Void
    let startMeeting: () -> Void
    let playRecording: () -> Void
    let stopMeeting: () -> Void
    let openSettings: () -> Void
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if backend.state == .stopping { stopping }
            if store.history.count > 1 || store.isBrowsing { historyBar }
            if let hint = store.shown {
                if store.isBrowsing, let u = store.spoken[hint.id] {
                    Text("In reply to \(u.speaker) [\(u.time)]: \(u.text)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HintCard(hint: hint, rate: { r in
                    store.rate(hint.id, r)
                    send(["type": "feedback", "id": hint.id, "rating": r, "session": store.session])
                })
            } else {
                idle
            }
            if let r = store.justRetracted, !store.isBrowsing {
                // bewust klein en grijs: wat niet meer klopt hoort niet de aandacht te trekken
                Text("Retracted (\(r.reason)): \(r.text)")
                    .font(.caption).strikethrough().foregroundStyle(.tertiary).lineLimit(1)
            }
            if !store.earlier.isEmpty && !store.isBrowsing {
                Divider()
                ForEach(store.earlier) { h in
                    Text(HintCard.bullets(h.text)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let last = store.utterances.last {
                Divider()
                Text("\(last.speaker): \(last.text)").font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
            if let path = store.summaryPath {
                Button("Open Report with Action Items") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .frame(width: layout.width, alignment: .topLeading)
        .frame(minHeight: layout.minHeight, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) { ResizeGrip(layout: layout).frame(width: 18, height: 18).padding(3) }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onReceive(timer) { tick = $0 }   // laat het regeltje over een ingetrokken hint na een paar seconden verdwijnen
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
                 + (store.shown.map { " · " + Self.clock.string(from: $0.updated) } ?? ""))
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

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Geen hint in beeld: wat de pijplijn doet, of knoppen om te beginnen.
    @ViewBuilder private var idle: some View {
        switch backend.state {
        case .running:
            Text(store.connected ? (store.status.isEmpty ? "Listening…" : store.status) : "Starting pipeline…")
                .font(.callout).foregroundStyle(.secondary)
        case .stopping:
            EmptyView()   // staat bovenaan in `stopping`, ook als er nog een hint in beeld is
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 8) {
                if case .failed(let why) = backend.state {
                    Text(why).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Knowledge base")
                    ProjectMenu(settings: settings).disabled(preparer.isRunning)
                    if !settings.project.isEmpty && !preparer.isRunning {
                        Button("Load KB") { preparer.startPrepare(settings) }
                            .help("In advance: update documents from the source folder, index the KB and load speech "
                                  + "recognition, so the meeting starts quickly")
                    }
                }
                .controlSize(.small)
                preparation
                TextField("Meeting info (e.g. with whom, where) – used in the report name", text: $settings.meetingInfo)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                if !settings.project.isEmpty {
                    HStack {
                        Button("Start Meeting · \(settings.projectLabel)") { startMeeting() }
                            .buttonStyle(.borderedProminent)
                        Button("Play Recording…") { playRecording() }
                    }
                    .controlSize(.small)
                    .disabled(preparer.isRunning)
                }
            }
        }
    }

    /// Voortgang of uitkomst van "KB laden": echte voortgang als de stap die meldt, anders een schatting
    /// uit de vorige keer, en alleen de allereerste keer een wieltje.
    private var preparation: some View { TaskProgressView(task: preparer, tick: tick) }

    /// Tijdens het afsluiten: wat de pijplijn nog doet en hoe lang al; de stappen hebben geen vaste duur.
    private var stopping: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quitting – waiting for the report").font(.callout.weight(.medium))
                Text(stoppingStep + (backend.stoppingSince.map { " · " + elapsed(since: $0) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Abort Now") { backend.abort() }
                .controlSize(.small).help("Don't wait for the report; the transcript is already saved or will be lost")
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var stoppingStep: String {
        // tot de pijplijn iets nieuws meldt, staat er nog "Luistert…"
        store.status.isEmpty || store.status == "Listening…" ? "Processing the last utterance…" : store.status
    }

    private func seconds(_ s: Double) -> String {
        s < 90 ? "\(Int(s.rounded())) s" : "\(Int((s / 60).rounded())) min"
    }

    private func elapsed(since start: Date) -> String {
        let s = max(0, Int(tick.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(backend.state == .running ? (store.connected ? Color.green : Color.orange) : Color.gray)
                .frame(width: 7, height: 7)
            Text("hint-meet").font(.caption.weight(.semibold))
            if !store.project.isEmpty { Text("· \(store.project)").font(.caption).foregroundStyle(.secondary) }
            if backend.isRunning && !settings.meetingInfo.isEmpty {
                Text("· \(settings.meetingInfo)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if backend.state == .running {
                Button("Stop") { stopMeeting() }.buttonStyle(.borderless).font(.caption)
            }
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
        }
    }
}

struct HintCard: View {
    let hint: Hint
    let rate: (Int) -> Void

    /// "- punt" van het model als "• punt" tonen.
    static func bullets(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") || t.hasPrefix("* ") ? "• " + t.dropFirst(2) : String(line)
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // wat je kunt zeggen: groot, met een accentbalk ervoor zodat het in één blik te vinden is
            Text(HintCard.bullets(hint.text) + (hint.state == .streaming ? " …" : ""))
                .font(.system(size: 19, weight: hint.state == .final ? .semibold : .regular))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.vertical, 8).padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(hint.state == .final ? 0.14 : 0.06),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 4).padding(.vertical, 4)
                }
            switch hint.state {
            case .retracted:
                EmptyView()  // komt hier niet: ingetrokken hints staan als regeltje in de overlay
            case .streaming:
                Text("checking source").font(.caption).foregroundStyle(.secondary)
            case .final:
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(hint.sources, id: \.self) { s in
                            Button((s.ref as NSString).lastPathComponent) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: s.path))
                            }
                            .buttonStyle(.link).font(.caption).lineLimit(1).help(s.path)
                        }
                    }
                    Spacer()
                    Button("👍") { rate(1) }.buttonStyle(.borderless).opacity(hint.rating == -1 ? 0.3 : 1)
                    Button("👎") { rate(-1) }.buttonStyle(.borderless).opacity(hint.rating == 1 ? 0.3 : 1)
                }
            }
        }
    }
}

/// Greep rechtsonder om het paneel groter of kleiner te slepen. Een randloos paneel dat geen focus
/// mag krijgen heeft geen sleepranden van macOS, en slepen op de achtergrond verplaatst het paneel.
struct ResizeGrip: NSViewRepresentable {
    let layout: PanelLayout

    func makeNSView(context: Context) -> GripView { GripView(layout: layout) }
    func updateNSView(_ view: GripView, context: Context) {}

    final class GripView: NSView {
        let layout: PanelLayout
        private var start: (mouse: NSPoint, width: CGFloat, height: CGFloat)?

        init(layout: PanelLayout) {
            self.layout = layout
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override var mouseDownCanMoveWindow: Bool { false }   // anders sleept het hele paneel mee
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.tertiaryLabelColor.setStroke()
            let path = NSBezierPath()
            for i in 1...3 {   // drie schuine streepjes, zoals een klassieke venstergreep
                let d = CGFloat(i) * 4
                path.move(to: NSPoint(x: bounds.maxX - d - 2, y: 2))
                path.line(to: NSPoint(x: bounds.maxX - 2, y: d + 2))
            }
            path.lineWidth = 1
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            start = (NSEvent.mouseLocation, window.frame.width, window.frame.height)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let now = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                layout.width = max(start.width + now.x - start.mouse.x, PanelLayout.minWidth)
                layout.minHeight = max(start.height - (now.y - start.mouse.y), 0)   // schermcoördinaten: y omhoog
            }
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
            MainActor.assumeIsolated {
                layout.clamp(to: window?.screen?.visibleFrame.size)
                layout.save()
            }
        }
    }
}
