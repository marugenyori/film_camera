import AVFoundation
import UIKit

/// ゲームの音（効果音と BGM）と振動。音のファイルは持たず、その場で音を合成する。
/// パチンコのような、高くてキラキラした金属的な音が基本（低音は控えめ）。
/// 効果音は「パチッ（ノイズ）＋キュイン（音程が駆け上がる）＋チン（鐘）＋ジャラジャラ（玉の音）」を重ねる。
/// BGM はドラム・ベース・和音・16 分のアルペジオ・メロディを鳴らし、全体に残響をかける。
/// マナーモードでも鳴らす（ゲーム中の右上のボタンで消せる）
final class GameAudio {
    static let shared = GameAudio()

    /// 音を出すか（ゲームの画面のボタンで切り替え、次回も覚えておく）
    var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: "gameMuted") }
        set {
            UserDefaults.standard.set(newValue, forKey: "gameMuted")
            lock.lock(); muted = newValue; lock.unlock()
        }
    }

    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private var source: AVAudioSourceNode?
    private let lock = NSLock()
    private var sampleRate: Double = 44_100
    private var started = false

    // 以下は lock で守る（音を作る処理は別のスレッドで動く）
    private var muted = false
    private var voices: [Voice] = []
    private var music: Sequencer?

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notify = UINotificationFeedbackGenerator()

    private init() {
        muted = UserDefaults.standard.bool(forKey: "gameMuted")
    }

    // MARK: - 始める・止める

    func start() {
        guard !started else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        let output = engine.outputNode.inputFormat(forBus: 0)
        sampleRate = output.sampleRate > 0 ? output.sampleRate : 44_100
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, bufferList in
            self?.render(frameCount: Int(frameCount), bufferList: bufferList)
            return noErr
        }
        engine.attach(node)
        engine.attach(reverb)
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 20
        engine.connect(node, to: reverb, format: mono)
        engine.connect(reverb, to: engine.mainMixerNode, format: mono)
        engine.mainMixerNode.outputVolume = 0.9
        source = node
        do {
            try engine.start()
            started = true
        } catch {
            started = false
        }
        light.prepare(); medium.prepare(); heavy.prepare()
    }

    func stop() {
        stopMusic()
        guard started else { return }
        engine.stop()
        if let source { engine.detach(source) }
        engine.detach(reverb)
        source = nil
        started = false
        lock.lock(); voices.removeAll(); lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - BGM

    /// BGM の曲（ノリのいいキャンディ風／きらきらした塗り絵風）
    enum Song { case candy, jewel, school, love }

    func playMusic(_ song: Song) {
        start()
        lock.lock()
        music = Sequencer(song: song, sampleRate: sampleRate)
        lock.unlock()
    }

    func stopMusic() {
        lock.lock(); music = nil; lock.unlock()
    }

    // MARK: - 効果音

    enum Effect {
        case tap, place, swap, invalid, pop(combo: Int), special, bomb, win, lose, complete
    }

    func play(_ effect: Effect) {
        start()
        var add: [Voice] = []
        let sr = sampleRate
        switch effect {
        case .tap:
            light.impactOccurred(intensity: 0.5)
            add += Voice.click(sr, volume: 0.25)
            add.append(Voice(sr, f0: 1800, f1: 2400, length: 0.05, wave: .sine, volume: 0.15))
        case .place:
            rigid.impactOccurred(intensity: 0.7)
            let pentatonic: [Double] = [0, 2, 4, 7, 9, 12]
            let note = 84 + (pentatonic.randomElement() ?? 0)
            add += Voice.click(sr, volume: 0.22)
            add.append(Voice(sr, f0: midi(note), length: 0.35, wave: .bell, volume: 0.22, decay: 5))
            add.append(Voice(sr, f0: midi(note + 12), length: 0.25, wave: .sine, volume: 0.07, delay: 0.02, decay: 7))
            add += Voice.balls(sr, count: 2, volume: 0.07, spread: 0.06)
        case .swap:
            light.impactOccurred()
            add.append(Voice(sr, f0: 0, length: 0.1, wave: .noise, volume: 0.16, decay: 4, filter: 0.08))
            add.append(Voice(sr, f0: 480, f1: 820, length: 0.09, wave: .triangle, volume: 0.18))
        case .invalid:
            notify.notificationOccurred(.warning)
            add.append(Voice(sr, f0: 300, f1: 220, length: 0.16, wave: .square, volume: 0.1, filter: 0.15))
        case .pop(let combo):
            let strength = min(1, 0.65 + Double(combo) * 0.1)
            heavy.impactOccurred(intensity: strength)
            // 連鎖するほど高く、厚く
            let step = Double(min(combo - 1, 8)) * 2
            let base = midi(72 + step)
            add += Voice.click(sr, volume: 0.32, crack: true)
            // キュイン：高く駆け上がる
            add.append(Voice(sr, f0: base * 0.9, f1: base * 2.6, length: 0.12, wave: .square, volume: 0.1, decay: 2, filter: 0.35))
            add.append(Voice(sr, f0: base, f1: base * 2.2, length: 0.1, wave: .sine, volume: 0.22, decay: 3))
            // チン・チン：鐘を細かく重ねる
            for (i, ratio) in [2.0, 2.52, 3.0, 4.0, 5.04].prefix(2 + min(combo, 3)).enumerated() {
                add.append(Voice(sr, f0: base * ratio, length: 0.35, wave: .bell, volume: 0.1,
                                 delay: 0.03 * Double(i), decay: 5))
            }
            // ジャラジャラ：連鎖するほど玉が増える
            add += Voice.balls(sr, count: 5 + min(combo, 8) * 2, volume: 0.07, spread: 0.12 + 0.03 * Double(min(combo, 8)))
        case .special:
            heavy.impactOccurred()
            add.append(Voice(sr, f0: 0, length: 0.3, wave: .noise, volume: 0.12, decay: 3, filter: 0.5, highPass: true))
            add.append(Voice(sr, f0: midi(76), f1: midi(100), length: 0.3, wave: .square, volume: 0.07, decay: 1.5, filter: 0.4))
            for (i, n) in [84.0, 88, 91, 96, 100].enumerated() {
                add.append(Voice(sr, f0: midi(n), length: 0.35, wave: .bell, volume: 0.12,
                                 delay: 0.045 * Double(i), decay: 5))
            }
            add += Voice.balls(sr, count: 14, volume: 0.07, spread: 0.35)
        case .bomb:
            heavy.impactOccurred(intensity: 1)
            add.append(Voice(sr, f0: 0, length: 0.5, wave: .noise, volume: 0.3, decay: 3.5, filter: 0.3, highPass: true))
            add += Voice.click(sr, volume: 0.45, crack: true)
            // キュイーン：長く駆け上がる
            add.append(Voice(sr, f0: midi(64), f1: midi(103), length: 0.55, wave: .square, volume: 0.09, decay: 1.2, filter: 0.4))
            add.append(Voice(sr, f0: midi(76), f1: midi(108), length: 0.5, wave: .sine, volume: 0.12, decay: 1.5))
            for (i, n) in [84.0, 88, 91, 96, 100, 103].enumerated() {
                add.append(Voice(sr, f0: midi(n), length: 0.45, wave: .bell, volume: 0.1, delay: 0.1 + 0.05 * Double(i), decay: 4))
            }
            add += Voice.balls(sr, count: 30, volume: 0.07, spread: 0.7)
        case .win, .complete:
            notify.notificationOccurred(.success)
            // パンパカパーン（高めのファンファーレ）
            let chords: [[Double]] = [[72, 76, 79], [72, 76, 79], [77, 81, 84], [79, 83, 86], [84, 88, 91, 96]]
            let times: [Double] = [0, 0.12, 0.24, 0.42, 0.6]
            for (i, chord) in chords.enumerated() {
                let last = i == chords.count - 1
                for n in chord {
                    add.append(Voice(sr, f0: midi(n), length: last ? 1.3 : 0.16, wave: .square, volume: 0.04,
                                     delay: times[i], decay: last ? 1.8 : 3, filter: 0.3))
                    add.append(Voice(sr, f0: midi(n + 12), length: 0.6, wave: .bell, volume: 0.05,
                                     delay: times[i], decay: 4))
                }
            }
            add.append(Voice(sr, f0: midi(72), f1: midi(108), length: 0.6, wave: .sine, volume: 0.08, delay: 0.6, decay: 1.5))
            // 玉があふれ出す
            add += Voice.balls(sr, count: 60, volume: 0.06, spread: 1.8, start: 0.6)
        case .lose:
            notify.notificationOccurred(.error)
            for (i, n) in [67.0, 63, 60, 55].enumerated() {
                add.append(Voice(sr, f0: midi(n), length: 0.4, wave: .triangle, volume: 0.2, delay: 0.2 * Double(i), decay: 3))
            }
        }
        lock.lock()
        voices.append(contentsOf: add)
        if voices.count > 200 { voices.removeFirst(voices.count - 200) }
        lock.unlock()
    }

    /// 振動だけ（音なし）
    func tick() { light.impactOccurred(intensity: 0.4) }

    // MARK: - 音を作る（オーディオのスレッドで呼ばれる）

    private func render(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<frameCount {
            var sample: Double = 0
            if !muted {
                if music != nil, let events = music?.advance() { voices.append(contentsOf: events) }
                for v in voices.indices { sample += voices[v].next() }
            }
            // やわらかく音割れを防ぐ
            data[i] = Float(tanh(sample * 1.1))
        }
        voices.removeAll { $0.isFinished }
        for buffer in buffers.dropFirst() {
            buffer.mData?.copyMemory(from: data, byteCount: frameCount * MemoryLayout<Float>.size)
        }
    }
}

private func midi(_ note: Double) -> Double { 440 * pow(2, (note - 69) / 12) }

private enum Wave { case sine, triangle, square, saw, noise, bell }

/// 1 つの音：音程の移り変わり（f0 → f1）、立ち上がりと減り方、ノイズや音色のフィルタ
private struct Voice {
    let f0: Double
    let f1: Double
    let length: Int
    let wave: Wave
    let volume: Double
    let decay: Double
    let attack: Int
    let filter: Double       // 1 = フィルタなし。小さいほどこもる（ローパス）
    let highPass: Bool
    var delay: Int
    var position = 0
    var phase = 0.0
    var low = 0.0

    init(_ sampleRate: Double, f0: Double, f1: Double? = nil, length: Double, wave: Wave, volume: Double,
         delay: Double = 0, decay: Double = 2.5, attack: Double = 0.002, filter: Double = 1, highPass: Bool = false) {
        self.f0 = f0
        self.f1 = f1 ?? f0
        self.length = max(1, Int(length * sampleRate))
        self.wave = wave
        self.volume = volume
        self.delay = Int(delay * sampleRate)
        self.decay = decay
        self.attack = max(1, Int(attack * sampleRate))
        self.filter = filter
        self.highPass = highPass
        self.sampleRate = sampleRate
    }

    let sampleRate: Double

    var isFinished: Bool { delay <= 0 && position >= length }

    /// パチッという短い音（crack は割れるような高い成分を足す）
    static func click(_ sr: Double, volume: Double, crack: Bool = false) -> [Voice] {
        var list = [Voice(sr, f0: 0, length: 0.03, wave: .noise, volume: volume, decay: 8, highPass: true)]
        if crack {
            list.append(Voice(sr, f0: 0, length: 0.09, wave: .noise, volume: volume * 0.6, decay: 6, filter: 0.35, highPass: true))
        }
        return list
    }

    /// ジャラジャラ：パチンコ玉がぶつかり合うような、短く高い金属音をばらばらに鳴らす
    static func balls(_ sr: Double, count: Int, volume: Double, spread: Double, start: Double = 0) -> [Voice] {
        (0..<count).flatMap { _ -> [Voice] in
            let at = start + Double.random(in: 0...spread)
            let pitch = Double.random(in: 2600...5200)
            return [
                Voice(sr, f0: pitch, length: Double.random(in: 0.03...0.07), wave: .bell, volume: volume * Double.random(in: 0.5...1),
                      delay: at, decay: 7),
                Voice(sr, f0: 0, length: 0.008, wave: .noise, volume: volume * 0.6, delay: at, decay: 8, highPass: true),
            ]
        }
    }

    mutating func next() -> Double {
        if delay > 0 { delay -= 1; return 0 }
        guard position < length else { return 0 }
        let t = Double(position) / Double(length)
        let rise = min(1, Double(position) / Double(attack))
        let envelope = rise * exp(-decay * t) * (1 - t)
        let frequency = f0 == f1 ? f0 : f0 * pow(f1 / max(f0, 1), t)
        phase += frequency / sampleRate
        if phase >= 1 { phase -= floor(phase) }
        position += 1
        var x: Double
        switch wave {
        case .sine: x = sin(phase * 2 * .pi)
        case .triangle: x = 4 * abs(phase - 0.5) - 1
        case .square: x = phase < 0.5 ? 0.7 : -0.7
        case .saw: x = 2 * phase - 1
        case .noise: x = Double.random(in: -1...1)
        case .bell:
            // FM で金属的なきらめき（時間とともにやわらかく）
            x = sin(2 * .pi * phase + 1.8 * exp(-4 * t) * sin(2 * .pi * phase * 3.5))
        }
        if filter < 1 || highPass {
            low += min(1, filter) * (x - low)
            x = highPass ? x - low : low
        }
        return x * envelope * volume
    }
}

/// BGM の演奏係：16 分音符ごとに、ドラム・ベース・和音・メロディの音を出す
private struct Sequencer {
    let sampleRate: Double
    let stepLength: Int
    let song: GameAudio.Song
    var sampleInStep = 0
    var step = 0

    // 曲のデータ：小節ごとの和音（MIDI の音の高さ）とメロディ（16 分音符 16 個、-1 は休み）
    let chords: [[Double]]
    let melody: [[Double]]

    init(song: GameAudio.Song, sampleRate: Double) {
        self.song = song
        self.sampleRate = sampleRate
        switch song {
        case .candy:
            // C → G → Am → F、テンポ 128 の四つ打ち
            stepLength = Int(sampleRate * 60 / 128 / 4)
            chords = [[48, 60, 64, 67], [43, 59, 62, 67], [45, 60, 64, 69], [41, 60, 65, 69]]
            melody = [
                [76, -1, 79, -1, 84, -1, 79, 76, -1, 74, 76, -1, 79, -1, -1, -1],
                [74, -1, 79, -1, 83, -1, 79, 74, -1, 71, 74, -1, 79, -1, 81, -1],
                [76, -1, 81, -1, 84, -1, 81, 76, -1, 72, 76, -1, 81, -1, -1, -1],
                [77, -1, 81, -1, 84, -1, 86, 84, -1, 81, 79, -1, 77, -1, 76, -1],
            ]
        case .school:
            // 恋愛アドベンチャーの日常曲：C → Am → F → G、テンポ 100 の明るい曲
            stepLength = Int(sampleRate * 60 / 100 / 4)
            chords = [[48, 60, 64, 67], [45, 57, 60, 64], [41, 57, 60, 65], [43, 55, 59, 62]]
            melody = [
                [72, -1, 74, -1, 76, -1, 79, -1, 76, -1, 74, -1, 72, -1, -1, -1],
                [69, -1, 72, -1, 76, -1, 72, -1, 74, -1, 72, -1, 69, -1, -1, -1],
                [65, -1, 69, -1, 72, -1, 77, -1, 76, -1, 74, -1, 72, -1, 69, -1],
                [67, -1, 71, -1, 74, -1, 79, -1, 77, -1, 76, -1, 74, -1, -1, -1],
            ]
        case .love:
            // 告白の曲：F → G → Em → Am、テンポ 76、ドラムなし
            stepLength = Int(sampleRate * 60 / 76 / 4)
            chords = [[41, 57, 60, 65], [43, 55, 59, 62], [40, 55, 59, 64], [45, 57, 60, 64]]
            melody = [
                [77, -1, -1, -1, 76, -1, 72, -1, 74, -1, -1, -1, 72, -1, -1, -1],
                [74, -1, -1, -1, 72, -1, 71, -1, 67, -1, -1, -1, -1, -1, -1, -1],
                [71, -1, -1, -1, 72, -1, 74, -1, 76, -1, -1, -1, 79, -1, -1, -1],
                [76, -1, -1, -1, 74, -1, 72, -1, 72, -1, -1, -1, -1, -1, -1, -1],
            ]
        case .jewel:
            // Fmaj7 → Em7 → Dm7 → Cmaj7、テンポ 100 のゆったりしたビート
            stepLength = Int(sampleRate * 60 / 100 / 4)
            chords = [[41, 64, 69, 72], [40, 62, 67, 71], [38, 60, 65, 69], [36, 59, 64, 67]]
            melody = [
                [84, -1, 81, -1, 76, -1, 81, -1, 84, -1, 88, -1, 86, -1, -1, -1],
                [83, -1, 79, -1, 74, -1, 79, -1, 83, -1, 86, -1, 83, -1, -1, -1],
                [81, -1, 77, -1, 72, -1, 77, -1, 81, -1, 84, -1, 81, -1, 79, -1],
                [79, -1, 76, -1, 71, -1, 76, -1, 79, -1, 83, -1, 84, -1, -1, -1],
            ]
        }
    }

    /// 1 サンプル進める。16 分音符の頭なら、その拍で鳴らす音を返す
    mutating func advance() -> [Voice]? {
        defer {
            sampleInStep += 1
            if sampleInStep >= stepLength {
                sampleInStep = 0
                step += 1
            }
        }
        guard sampleInStep == 0 else { return nil }
        return events(at: step)
    }

    private func events(at step: Int) -> [Voice] {
        let sr = sampleRate
        let s = step % 16
        let bar = (step / 16) % chords.count
        let chord = chords[bar]
        let stepSeconds = Double(stepLength) / sampleRate
        var out: [Voice] = []
        let candy = song == .candy
        let drums = song != .love

        // ドラム
        if drums, candy ? s % 4 == 0 : (s == 0 || s == 8 || s == 11) {
            out.append(Voice(sr, f0: 220, f1: 90, length: 0.07, wave: .sine, volume: candy ? 0.22 : 0.14, decay: 4))
            out.append(Voice(sr, f0: 0, length: 0.012, wave: .noise, volume: 0.15, decay: 6, highPass: true))
        }
        if drums, s == 4 || s == 12 {
            if candy {
                out.append(Voice(sr, f0: 0, length: 0.18, wave: .noise, volume: 0.3, decay: 4, filter: 0.5, highPass: true))
                out.append(Voice(sr, f0: 240, f1: 180, length: 0.09, wave: .triangle, volume: 0.18))
            } else {
                out.append(Voice(sr, f0: 900, length: 0.05, wave: .bell, volume: 0.12, decay: 8))   // リム
            }
        }
        if drums, candy || s % 2 == 0 {
            let open = candy && s % 4 == 2
            out.append(Voice(sr, f0: 0, length: open ? 0.12 : 0.035, wave: .noise,
                             volume: s % 2 == 0 ? 0.09 : 0.05, decay: open ? 4 : 9, filter: 0.9, highPass: true))
        }
        // ベース（和音の根音。キャンディは跳ねるリズム）
        let bassSteps: Set<Int> = candy ? [0, 3, 6, 8, 10, 11, 14] : [0, 6, 8, 14]
        if bassSteps.contains(s) {
            let octave: Double = candy && s % 2 == 1 ? 24 : 12
            out.append(Voice(sr, f0: midi(chord[0] + octave), length: stepSeconds * (candy ? 1.2 : 2.5),
                             wave: candy ? .square : .triangle, volume: candy ? 0.05 : 0.08, decay: 3, filter: 0.2))
        }
        // 和音（小節の頭でふわっと。キャンディは裏拍でも刻む）
        if s == 0 {
            for note in chord.dropFirst() {
                out.append(Voice(sr, f0: midi(note), length: stepSeconds * 16, wave: .saw, volume: 0.035,
                                 decay: 1, attack: 0.25, filter: 0.04))
                out.append(Voice(sr, f0: midi(note) * 1.006, length: stepSeconds * 16, wave: .saw, volume: 0.03,
                                 decay: 1, attack: 0.25, filter: 0.04))
            }
        }
        if candy && (s == 2 || s == 6 || s == 10 || s == 14) {
            for note in chord.dropFirst() {
                out.append(Voice(sr, f0: midi(note + 12), length: stepSeconds * 1.2, wave: .square, volume: 0.025,
                                 decay: 4, filter: 0.25))
            }
        }
        // 16 分のアルペジオ（パチンコらしい、高くて細かいキラキラ）
        if candy || s % 2 == 0 {
            let tones = chord.dropFirst().map { $0 + 24 }
            let arp = tones[(candy ? s : s / 2) % tones.count]
            out.append(Voice(sr, f0: midi(arp), length: stepSeconds * 0.9, wave: candy ? .square : .bell,
                             volume: candy ? 0.022 : 0.04, decay: 5, filter: candy ? 0.5 : 1))
        }
        // 小節の頭に「チーン」
        if s == 0 {
            out.append(Voice(sr, f0: midi(chord[1] + 24), length: 0.8, wave: .bell, volume: 0.06, decay: 3))
        }
        // メロディ（こだまのように少し遅れてもう一度小さく）
        let note = melody[bar][s]
        if note >= 0 {
            if candy {
                out.append(Voice(sr, f0: midi(note), length: stepSeconds * 1.8, wave: .square, volume: 0.08, decay: 3, filter: 0.45))
                out.append(Voice(sr, f0: midi(note), length: stepSeconds * 1.8, wave: .triangle, volume: 0.07, decay: 3))
                out.append(Voice(sr, f0: midi(note + 12), length: 0.3, wave: .bell, volume: 0.04, decay: 5))
                out.append(Voice(sr, f0: midi(note), length: stepSeconds * 1.8, wave: .square, volume: 0.025,
                                 delay: stepSeconds * 3, decay: 3, filter: 0.2))
            } else {
                out.append(Voice(sr, f0: midi(note), length: 0.6, wave: .bell, volume: 0.12, decay: 4))
                out.append(Voice(sr, f0: midi(note), length: 0.6, wave: .bell, volume: 0.045, delay: stepSeconds * 3, decay: 4))
            }
        }
        return out
    }
}
