import AVFoundation
import Observation
import SwiftUI

/// Plays one audio file and reports its progress.
@MainActor
@Observable
final class AudioPlayback {
    let url: URL
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var failed = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    func load() {
        guard player == nil, !failed else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
        } catch {
            failed = true
        }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        load()
        guard let player else { return }
        #if os(iOS)
        // Plays even with the ring/silent switch on, like Voice Memos.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
        currentTime = player?.currentTime ?? currentTime
    }

    func seek(to time: TimeInterval) {
        load()
        guard let player else { return }
        player.currentTime = min(max(0, time), duration)
        currentTime = player.currentTime
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    /// Stops playback and hands the audio session back to other apps.
    func stop() {
        pause()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    // Reached the end.
                    self.isPlaying = false
                    self.currentTime = player.currentTime >= self.duration - 0.05 ? 0 : player.currentTime
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// A simple player for a voice memo or other audio: play and pause, skip 15 seconds, and a scrubber.
// DECISION: a basic player for Phase 2. Speeds, a waveform and tap-to-seek transcripts come
// with the full recorder in Phase 5.
public struct AudioPlayerView: View {
    let title: String?
    @State private var playback: AudioPlayback
    @State private var scrubTime: TimeInterval?

    public init(url: URL, title: String?) {
        self.title = title
        _playback = State(initialValue: AudioPlayback(url: url))
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 120, height: 120)
                .background(.white.opacity(0.08), in: .circle)
                .symbolEffect(.variableColor.iterative, isActive: playback.isPlaying)

            if let title {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal)
            }

            if playback.failed {
                Text("This recording couldn't be played.", bundle: .module)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(get: { scrubTime ?? playback.currentTime }, set: { scrubTime = $0 }),
                        in: 0...max(playback.duration, 0.1),
                        onEditingChanged: { editing in
                            if !editing, let scrubTime {
                                playback.seek(to: scrubTime)
                                self.scrubTime = nil
                            }
                        }
                    )
                    HStack {
                        Text(Self.format(scrubTime ?? playback.currentTime))
                        Spacer()
                        Text(verbatim: "-" + Self.format(max(0, playback.duration - (scrubTime ?? playback.currentTime))))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)

                HStack(spacing: 44) {
                    Button { playback.skip(by: -15) } label: {
                        Label { Text("Back 15 Seconds", bundle: .module) } icon: { Image(systemName: "gobackward.15") }
                    }
                    Button { playback.toggle() } label: {
                        Label {
                            playback.isPlaying ? Text("Pause", bundle: .module) : Text("Play", bundle: .module)
                        } icon: {
                            Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 64))
                        }
                    }
                    Button { playback.skip(by: 15) } label: {
                        Label { Text("Forward 15 Seconds", bundle: .module) } icon: { Image(systemName: "goforward.15") }
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title)
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { playback.load() }
        .onDisappear { playback.stop() }
    }

    static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.isFinite ? seconds : 0).formatted(.time(pattern: .minuteSecond))
    }
}
