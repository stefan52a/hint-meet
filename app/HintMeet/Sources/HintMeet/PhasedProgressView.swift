import SwiftUI

/// Voortgang van Load KB / Add Folder per fase (bijwerken, model, lezen, woordindex, embeddings,
/// spraakherkenning), met bovenaan de totaalvoortgang. Valt terug op TaskProgressView zonder plan.
struct PhasedProgressView: View {
    @ObservedObject var task: ProgressTask
    let tick: Date

    var body: some View {
        if task.phases.isEmpty {
            TaskProgressView(task: task, tick: tick)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                if task.isRunning, let overall = task.overall(at: tick) {
                    HStack(spacing: 8) {
                        Text(task.title).font(.caption.weight(.semibold))
                        ProgressView(value: overall).frame(maxWidth: .infinity)
                        Text("\(Int((overall * 100).rounded()))%").font(.caption).monospacedDigit()
                        Text(task.since.map { TaskProgressView.elapsed(from: $0, to: tick) } ?? "")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Button("Stop") { task.stop() }.controlSize(.small)
                            .help("Stop; finished work is kept and Load KB continues where it left off")
                    }
                }
                ForEach(task.phases) { phase in row(phase) }
                if !task.isRunning { TaskProgressView(task: task, tick: tick) }   // uitkomst en logboek
            }
        }
    }

    private func row(_ p: ProgressTask.Phase) -> some View {
        HStack(spacing: 6) {
            Group {
                switch p.status {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .running: ProgressView().controlSize(.mini)
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 14)
            Text(p.label).font(.caption).foregroundStyle(p.status == .pending ? .secondary : .primary)
            if p.status == .running {
                if let f = p.fraction {
                    ProgressView(value: f).frame(width: 90)
                } else if let guess = task.estimate(at: tick) {
                    ProgressView(value: guess.fraction).frame(width: 90)
                }
                Text(p.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}
