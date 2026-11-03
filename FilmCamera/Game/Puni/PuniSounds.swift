import AVFoundation

/// ぷにぷにシューターの効果音。本家 sobosuba の体験版が使っているのと同じ音のファイルを鳴らす
/// （どれも freesound.org で公開されている音で、CC0 か CC BY。くっつく音だけ CC BY なので、メニューに作者名を出す）。
/// 本家の設定（音量・音程・音程の変え方）と、本家の全体にかかっている残響もまねる。
/// ファイルは `Sounds/` の `puni_*.caf`（ALAC。元の音をそのまま、可逆圧縮で入れてある）
final class PuniSounds {
    static let shared = PuniSounds()

    enum Sample: String, CaseIterable {
        /// くっつく（339343 soft blip E major / newagesoup / CC BY 4.0）
        case merge = "puni_merge"
        /// 撃つ（425209 water drop / velkstar / CC0）
        case launch = "puni_launch"
        /// 両方のゲージがいっぱいになった瞬間（523754 new skill 02 / lilmati / CC0）
        case loss = "puni_loss"
        /// 実績（619834 correct menu / cogfirestudios / CC0）
        case achievement = "puni_achievement"
        /// ゲームオーバーの画面（827122 end of task / xkeril / CC0）
        case gameOver = "puni_gameover"
        /// ゲームの始まり（827123 startup sound / xkeril / CC0）
        case start = "puni_start"
        /// 点数が数え上がる間（468927 medium text blip / malakme / CC0）
        case score = "puni_score"
        /// 左右の半円に触れている間（661948 alarm / bloodpixelhero / CC0。本家と同じく音を大きくし、高い音を少し削った）
        case danger = "puni_danger"
    }

    /// メニューに出す、音の作者の表記（CC BY の音があるため）
    static let credits = "音：freesound.org より newagesoup「soft blip E major」（CC BY 4.0）ほか CC0 の音"

    private final class Clip {
        let left: [Float]
        let right: [Float]
        let sampleRate: Double
        init(left: [Float], right: [Float], sampleRate: Double) {
            self.left = left
            self.right = right
            self.sampleRate = sampleRate
        }
        var count: Int { left.count }
    }

    private struct Voice {
        let clip: Clip
        var position: Double = 0
        var rate: Double
        var gain: Float
        var delay: Int
        var isFinished: Bool { position >= Double(clip.count - 1) }
    }

    /// 鳴らし続ける音（警告音・点数の音）。音量と音程はなめらかに変える
    private struct Loop {
        var position: Double = 0
        var gain: Float = 0
        var targetGain: Float = 0
        var pitch: Double = 1
    }

    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private var source: AVAudioSourceNode?
    private var started = false
    private var outputRate: Double = 48_000
    private var clips: [Sample: Clip] = [:]
    private var tick: Clip?

    // 以下は lock で守る
    private let lock = NSLock()
    private var voices: [Voice] = []
    private var dangerLoop = Loop()
    private var scoreLoop = Loop()
    private var muted = false

    private init() {}

    /// 音を消す設定（ほかのゲームと共通）を読み直す
    func refreshMuted() {
        lock.lock(); muted = UserDefaults.standard.bool(forKey: "gameMuted"); lock.unlock()
    }

    private func start() {
        refreshMuted()
        if started {
            // 電話・ほかのアプリ・イヤホンの抜き差しなどで止まっていたら、動かし直す
            if !engine.isRunning {
                try? AVAudioSession.sharedInstance().setActive(true)
                try? engine.start()
            }
            return
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        let output = engine.outputNode.inputFormat(forBus: 0)
        outputRate = output.sampleRate > 0 ? output.sampleRate : 48_000
        for sample in Sample.allCases { clips[sample] = Self.load(sample.rawValue) }
        tick = Self.makeTick(sampleRate: outputRate)
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2) else { return }
        let node = AVAudioSourceNode(format: stereo) { [weak self] _, _, frameCount, bufferList in
            self?.render(frameCount: Int(frameCount), bufferList: bufferList)
            return noErr
        }
        engine.attach(node)
        engine.attach(reverb)
        // 本家は全体に残響（部屋の大きさ 0.4、高い音を残しやすく、元の音と半々）をかけている
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 30
        engine.connect(node, to: reverb, format: stereo)
        engine.connect(reverb, to: engine.mainMixerNode, format: stereo)
        source = node
        do {
            try engine.start()
            started = true
        } catch {
            started = false
        }
    }

    func stop() {
        guard started else { return }
        engine.stop()
        if let source { engine.detach(source) }
        engine.detach(reverb)
        source = nil
        started = false
        lock.lock()
        voices.removeAll()
        dangerLoop = Loop()
        scoreLoop = Loop()
        lock.unlock()
    }

    /// 1 回鳴らす。db は本家の volume_db、pitch は pitch_scale と同じ意味
    func play(_ sample: Sample, db: Float = 0, pitch: Double = 1, delay: Double = 0) {
        start()
        guard let clip = clips[sample] else { return }
        add(Voice(clip: clip, rate: clip.sampleRate / outputRate * pitch, gain: pow(10, db / 20),
                  delay: Int(delay * outputRate)))
    }

    /// くっつく音。本家は「面積が 15000 の玉で元の高さ」で、面積が 2 倍になるごとに
    /// 音程を 1/5 オクターブ下げ、3dB 大きくする。ここでは 4 の玉を本家の 15000 にあてる
    func merge(areaRatio: Float) {
        let octaves = log2(max(areaRatio, 0.01))
        play(.merge, db: min(max(octaves * 3, -12), 12), pitch: Double(pow(2, -octaves / 5)))
    }

    /// 矢印を引っぱるときの小さなカチッ（本家はパック素材の音で、使える条件が分からないので似せて作った音）
    func stretch(pitch: Double) {
        start()
        guard let tick else { return }
        add(Voice(clip: tick, rate: pitch, gain: 0.6, delay: 0))
    }

    /// 警告音を鳴らす・止める（本家は半円の押しこまれ具合で -40dB〜0dB）
    func setDanger(_ level: Float) {
        if level > 0 { start() }
        lock.lock()
        dangerLoop.targetGain = level > 0 ? pow(10, (-40 + 40 * min(level, 1)) / 20) : 0
        lock.unlock()
    }

    /// 点数が数え上がる間の音（残りが多いほど少し高く）
    func setScoreCounting(_ remaining: Int) {
        if remaining > 0 { start() }
        lock.lock()
        scoreLoop.targetGain = remaining > 0 ? 1 : 0
        scoreLoop.pitch = 1 + min(Double(remaining), 128) / 128 * 0.5
        lock.unlock()
    }

    private func add(_ voice: Voice) {
        lock.lock()
        voices.append(voice)
        if voices.count > 48 { voices.removeFirst(voices.count - 48) }
        lock.unlock()
    }

    // MARK: - 音を作る（オーディオのスレッド）

    private func render(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<frameCount { left[i] = 0; right[i] = 0 }
        guard !muted else { return }
        for index in voices.indices {
            var voice = voices[index]
            for i in 0..<frameCount {
                if voice.delay > 0 { voice.delay -= 1; continue }
                guard !voice.isFinished else { break }
                let (l, r) = Self.read(voice.clip, at: voice.position)
                left[i] += l * voice.gain
                right[i] += r * voice.gain
                voice.position += voice.rate
            }
            voices[index] = voice
        }
        voices.removeAll { $0.isFinished }
        mix(&dangerLoop, clip: clips[.danger], left: left, right: right, frameCount: frameCount)
        mix(&scoreLoop, clip: clips[.score], left: left, right: right, frameCount: frameCount)
        // 全体を少し下げて、割れないように抑える（本家は +9dB で鳴らす音がある）
        for i in 0..<frameCount {
            left[i] = max(-1, min(1, left[i] * 0.6))
            right[i] = max(-1, min(1, right[i] * 0.6))
        }
    }

    private func mix(_ loop: inout Loop, clip: Clip?, left: UnsafeMutablePointer<Float>,
                     right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard let clip, clip.count > 1, loop.gain > 0.0001 || loop.targetGain > 0 else {
            loop.position = 0
            loop.gain = 0
            return
        }
        let rate = clip.sampleRate / outputRate * loop.pitch
        // 音量は 0.05 秒ほどでなめらかに変える（ぷつっと鳴らないように）
        let smoothing = Float(1 / (0.05 * outputRate))
        for i in 0..<frameCount {
            loop.gain += (loop.targetGain - loop.gain) * smoothing
            let (l, r) = Self.read(clip, at: loop.position)
            left[i] += l * loop.gain
            right[i] += r * loop.gain
            loop.position += rate
            if loop.position >= Double(clip.count - 1) { loop.position -= Double(clip.count - 1) }
        }
    }

    private static func read(_ clip: Clip, at position: Double) -> (Float, Float) {
        let index = Int(position)
        let next = min(index + 1, clip.count - 1)
        let t = Float(position - Double(index))
        let l = clip.left[index] + (clip.left[next] - clip.left[index]) * t
        let r = clip.right[index] + (clip.right[next] - clip.right[index]) * t
        return (l, r)
    }

    // MARK: - 読みこみ

    private static func load(_ name: String) -> Clip? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf"),
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let left = Array(UnsafeBufferPointer(start: data[0], count: frames))
        let right = channels > 1 ? Array(UnsafeBufferPointer(start: data[1], count: frames)) : left
        return Clip(left: left, right: right, sampleRate: file.processingFormat.sampleRate)
    }

    /// 6 ミリ秒ほどの明るいカチッ（1.9kHz 付近の音とノイズ）
    private static func makeTick(sampleRate: Double) -> Clip {
        let count = Int(sampleRate * 0.03)
        var samples = [Float](repeating: 0, count: count)
        var low: Float = 0
        for i in 0..<count {
            let t = Float(Double(i) / sampleRate)
            let envelope = exp(-t / 0.004)
            let noise = Float.random(in: -1...1)
            low += 0.35 * (noise - low)
            samples[i] = (sin(2 * .pi * 1900 * t) * 0.6 + (noise - low) * 0.4) * envelope * 0.35
        }
        return Clip(left: samples, right: samples, sampleRate: sampleRate)
    }
}
