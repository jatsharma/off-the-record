import AVFoundation
import Foundation

/// Plays a meeting's WAV and publishes the playhead so the transcript can follow it.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL?) {
        guard url != loadedURL else { return }
        stop()
        loadedURL = url
        guard let url, let p = try? AVAudioPlayer(contentsOf: url) else { player = nil; duration = 0; return }
        p.prepareToPlay()
        player = p
        duration = p.duration
    }

    func toggle() { isPlaying ? pause() : play() }

    func play(from time: Double? = nil) {
        guard let player else { return }
        if let time { player.currentTime = max(0, min(time, player.duration)) }
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying { self.isPlaying = false; self.timer?.invalidate() }
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func seek(to time: Double) {
        player?.currentTime = max(0, min(time, duration))
        currentTime = player?.currentTime ?? time
    }

    func stop() {
        pause()
        player?.currentTime = 0
        currentTime = 0
    }
}
