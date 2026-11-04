import AVFoundation
import Foundation

/// 把两条轨（或单个混音文件）叠成一条播放，点对话稿里的时间戳就跳到那里。
@MainActor
final class AudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1 {
        didSet { if let p = player, p.rate > 0 { p.rate = rate } }
    }

    private var player: AVPlayer?
    private var observer: Any?
    private var loaded: [URL] = []

    func load(_ urls: [URL]) async {
        guard urls != loaded else { return }
        loaded = urls
        stop()
        let comp = AVMutableComposition()
        var longest = CMTime.zero
        for u in urls {
            let asset = AVURLAsset(url: u)
            guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
                let dur = try? await asset.load(.duration),
                let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try? dst.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: .zero)
            if dur > longest { longest = dur }
        }
        guard urls == loaded else { return }
        let p = AVPlayer(playerItem: AVPlayerItem(asset: comp))
        player = p
        duration = longest.seconds.isFinite ? longest.seconds : 0
        time = 0
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { t in
            Task { @MainActor [weak self] in
                guard let self, let p = self.player else { return }
                self.time = t.seconds
                self.isPlaying = p.rate > 0
            }
        }
    }

    func play(at seconds: Double) {
        guard let p = player else { return }
        p.seek(to: CMTime(seconds: max(seconds - 0.5, 0), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        p.playImmediately(atRate: rate)
        isPlaying = true
    }

    func seek(_ seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        time = seconds
    }

    func toggle() {
        guard let p = player else { return }
        if p.rate > 0 { p.pause() } else { p.playImmediately(atRate: rate) }
        isPlaying = p.rate > 0
    }

    func skip(_ delta: Double) {
        seek(min(max(time + delta, 0), duration))
    }

    func stop() {
        player?.pause()
        if let o = observer { player?.removeTimeObserver(o) }
        observer = nil
        player = nil
        isPlaying = false
    }
}

func clock(_ t: Double) -> String {
    let s = Int(max(t, 0))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}
