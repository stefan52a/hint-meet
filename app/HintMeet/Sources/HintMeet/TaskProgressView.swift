import AppKit
import SwiftUI

/// Voortgang of uitkomst van een ProgressTask: echte voortgang als de stap die meldt, anders een schatting
/// uit de vorige keer, en alleen de allereerste keer een wieltje. `tick` laat de tijd elke seconde verspringen.
struct TaskProgressView: View {
    @ObservedObject var task: ProgressTask
    let tick: Date

    var body: some View {
        switch task.state {
        case .idle:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: 4) {
                let guess = task.estimate(at: tick)
                HStack(spacing: 8) {
                    if let f = task.fraction ?? guess?.fraction {
                        ProgressView(value: f).frame(maxWidth: .infinity)
                    } else {
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    Button("Stop") { task.stop() }.controlSize(.small)
                        .help("Stoppen; wat klaar is blijft bewaard en de volgende keer gaat hij verder")
                }
                Text(task.step + (guess.map { " · nog ~" + Self.seconds($0.left) + " (schatting)" } ?? "")
                     + (task.since.map { " · " + Self.elapsed(from: $0, to: tick) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        case .done(let msg):
            HStack {
                Text("✓ " + msg).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                logButton
            }
        case .failed(let why):
            HStack {
                Text(why).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer()
                logButton
            }
        }
    }

    private var logButton: some View {
        Button("Logboek") { NSWorkspace.shared.open(task.logURL) }.buttonStyle(.link).font(.caption)
    }

    static func seconds(_ s: Double) -> String {
        s < 90 ? "\(Int(s.rounded())) s" : "\(Int((s / 60).rounded())) min"
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
