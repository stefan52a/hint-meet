import AVFoundation
import Combine
import SwiftUI

/// De opname van de meeting afspelen na afloop, gekoppeld aan het transcript: de positie bepaalt welke uitspraak
/// oplicht, en een klik op een uitspraak springt naar dat moment.
@MainActor
final class Playback: ObservableObject {
    @Published private(set) var loadedPath: String?
    @Published private(set) var playing = false
    @Published private(set) var current: Double = 0      // seconden
    @Published private(set) var duration: Double = 0
    /// Ophogen bij een sprong (klik op een uitspraak, schuifbalk): het transcript volgt dan meteen.
    @Published private(set) var seekToken = 0
    private var player: AVPlayer?
    private var observer: Any?
    private var endWatch: AnyCancellable?

    var isLoaded: Bool { player != nil }

    func load(_ path: String) {
        guard loadedPath != path else { return }
        unload()
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let p = AVPlayer(playerItem: item)
        player = p
        loadedPath = path
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) {
            [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.current = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player?.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        endWatch = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.playing = false } }
        Task { [weak self] in   // de lengte alvast, voor de schuifbalk; alleen als dit nog de geladen opname is
            if let d = try? await item.asset.load(.duration).seconds, d.isFinite, self?.loadedPath == path {
                self?.duration = d
            }
        }
    }

    func unload() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        endWatch = nil
        player?.pause()
        player = nil
        loadedPath = nil
        playing = false
        current = 0
        duration = 0
    }

    func toggle() {
        guard let player else { return }
        if playing {
            player.pause()
        } else {
            if duration > 0, current >= duration - 0.3 { seek(to: 0) }   // aan het eind: opnieuw
            player.play()
        }
        playing.toggle()
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let t = max(0, min(seconds, duration > 0 ? duration : seconds))
        current = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        seekToken &+= 1
    }

    /// Naar het begin van een uitspraak ("mm:ss" uit het transcript); speelt verder als hij al speelde.
    func seek(toUtterance time: String) {
        if let s = Self.seconds(time) { seek(to: s) }
    }

    /// "mm:ss" of "h:mm:ss" → seconden.
    nonisolated static func seconds(_ time: String) -> Double? {
        let parts = time.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count == time.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    nonisolated static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Bediening onder het verslag: ▶/⏸, positie, schuifbalk.
struct PlaybackBar: View {
    @ObservedObject var playback: Playback
    let path: String

    var body: some View {
        if FileManager.default.fileExists(atPath: path) { controls }   // opname weg (verplaatst): geen speler
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                playback.load(path)
                playback.toggle()
            } label: {
                Image(systemName: playback.playing ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .help(playback.playing ? "Pause" : "Play the meeting audio; click a line in the transcript to jump there")
            .accessibilityLabel(playback.playing ? "Pause" : "Play meeting audio")
            Text(Playback.clock(playback.current)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Slider(value: Binding(get: { playback.current },
                                  set: { playback.load(path); playback.seek(to: $0) }),
                   in: 0...max(playback.duration, 1))
                .controlSize(.small)
                .accessibilityLabel("Position in the meeting audio")
            Text(Playback.clock(playback.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .onAppear { playback.load(path) }
        .onChange(of: path) { _, p in playback.load(p) }
    }
}
