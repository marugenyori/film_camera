import SwiftUI
import UIKit
import simd

/// 「ぷにぷにシューター」のルールと物理（Steam の sobosuba を手本にした、数字の玉をくっつけるゲーム）。
/// 黒い容器（下の角が斜め、左右の壁に半円の出っぱり）に、上の列から数字の玉（1, 2, 4, 8…）を撃ちこむ。
/// 同じ数字の玉がさわるとくっついて 2 倍の玉になる。点数は容器の中の数字の合計。玉が上の線をこえて 3 秒たつと終わり。
/// 玉は「やわらかい体」：まわりの点をばねでつなぎ、中の面積を保とうとする力（圧力）でふくらませる。
/// 押されるとすき間に合わせて形が変わり、ぎゅうぎゅうに詰まる
@MainActor
final class PuniGame: ObservableObject {
    typealias Vec = SIMD2<Float>

    struct Blob: Identifiable {
        let id: Int
        var level: Int
        var pos: [Vec]
        var prev: [Vec]
        /// いまめざしている面積（くっついた直後は 2 つ分から、本来の大きさへ少しずつ縮む）
        var area: Float
        var targetArea: Float
        var age: Double = 0
        /// くっついて生まれた直後の白い光（1 → 0）
        var flash: Double = 0
        /// 上の列（細い筒）の中にいる玉。重力ではなく筒の真ん中へ引かれ、押し合う
        var queued = false
        var minX: Float = 0, maxX: Float = 0, minY: Float = 0, maxY: Float = 0

        var value: Int { 1 << level }

        /// 向き（はじめの点が中心から見てどちらにあるか。数字を玉と一緒に回す）
        var rotation: Float {
            let offset = pos[0] - center
            return atan2(offset.y, offset.x)
        }

        var center: Vec {
            var sum = Vec(0, 0)
            for p in pos { sum += p }
            return sum / Float(pos.count)
        }

        /// いまの面積（点の順は時計回りの逆、y は下向き）
        var currentArea: Float {
            var total: Float = 0
            let count = pos.count
            for index in 0..<count {
                let a = pos[index], b = pos[(index + 1) % count]
                total += a.x * b.y - b.x * a.y
            }
            return total * 0.5
        }

        mutating func updateBounds() {
            var lowX = Float.infinity, highX = -Float.infinity, lowY = Float.infinity, highY = -Float.infinity
            for p in pos {
                lowX = min(lowX, p.x)
                highX = max(highX, p.x)
                lowY = min(lowY, p.y)
                highY = max(highY, p.y)
            }
            minX = lowX
            maxX = highX
            minY = lowY
            maxY = highY
        }

        /// 点が中にあるか
        func contains(_ point: Vec) -> Bool {
            guard point.x >= minX, point.x <= maxX, point.y >= minY, point.y <= maxY else { return false }
            var inside = false
            var j = pos.count - 1
            for i in 0..<pos.count {
                let a = pos[i], b = pos[j]
                if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
    }

    struct Popup: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    /// 数字ごとの色（1 赤・2 黄・4 緑・8 青緑・16 青・32 紫・64 ピンク・128 橙・256 黄緑・512 白・1024 水色・2048 濃い青・4096 赤紫）
    static let colors: [Color] = [
        Color(red: 1, green: 0.2, blue: 0.2), Color(red: 1, green: 0.92, blue: 0.2), Color(red: 0.37, green: 1, blue: 0.2),
        Color(red: 0.2, green: 1, blue: 0.75), Color(red: 0.2, green: 0.53, blue: 1), Color(red: 0.6, green: 0.2, blue: 1),
        Color(red: 1, green: 0.2, blue: 0.68), Color(red: 1, green: 0.45, blue: 0.2), Color(red: 0.85, green: 1, blue: 0.2),
        Color(white: 0.93), Color(red: 0.2, green: 1, blue: 1), Color(red: 0.2, green: 0.27, blue: 1),
        Color(red: 0.83, green: 0.2, blue: 1), Color(red: 1, green: 0.35, blue: 0.35), Color(red: 1, green: 0.8, blue: 0.2),
    ]

    static func color(_ level: Int) -> Color { colors[min(max(level, 0), colors.count - 1)] }

    @Published private(set) var frame = 0
    @Published private(set) var score = 0
    @Published private(set) var best = UserDefaults.standard.integer(forKey: "puniBest2")
    @Published private(set) var gameOver = false
    @Published var popup: Popup?

    private(set) var blobs: [Blob] = []
    /// 容器の中の大きさ（画面に合わせて決める）
    private(set) var width: Float = 340
    private(set) var height: Float = 360
    /// 上の線の危なさ（0〜1）
    private(set) var danger: Double = 0
    private var nextID = 0
    /// 点数の増え（右上に「+16」と出す）
    struct Gain: Identifiable {
        let id: Int
        let text: String
        var life: Double
    }
    private(set) var gains: [Gain] = []
    /// 続けてくっついたら「amass!」
    @Published private(set) var amass = 0
    private var combo = 0
    private var comboTimer: Double = 0
    private var accumulator: Double = 0
    private var biggest = 0
    private var achieved: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "puniAchievements") ?? [])
    private let haptic = UIImpactFeedbackGenerator(style: .soft)

    init() {}

    // MARK: - 形と大きさ

    /// 次の玉が並ぶ高さ・撃ち出す高さ
    var queueY: Float { height * 0.12 }
    /// これより上に玉が積み上がると危ない
    var dangerY: Float { height * 0.2 }
    /// 下の角を斜めに切る大きさ
    var chamfer: Float { width * 0.1 }
    /// 左右の壁の半円の出っぱり
    var bumperY: Float { height * 0.33 }
    var bumperRadius: Float { width * 0.065 }

    /// 数字の玉の半径（面積は数字の 0.42 乗に比例して大きくなる）
    func radius(_ level: Int) -> Float { width * 0.054 * pow(2, Float(level) * 0.209) }
    func area(_ level: Int) -> Float { let r = radius(level); return .pi * r * r }
    /// まわりの点の数（大きい玉ほど多い）
    func pointCount(_ level: Int) -> Int { min(max(Int(radius(level) * 2 * .pi / (width * 0.032)), 10), 30) }

    func layout(width newWidth: Float, height newHeight: Float) {
        guard newWidth > 50, abs(newWidth - width) > 0.5 || abs(newHeight - height) > 0.5 else { return }
        let sx = newWidth / width, sy = newHeight / height
        for index in blobs.indices {
            for p in blobs[index].pos.indices {
                blobs[index].pos[p] *= Vec(sx, sy)
                blobs[index].prev[p] *= Vec(sx, sy)
            }
            blobs[index].area *= sx * sx
            blobs[index].targetArea *= sx * sx
        }
        width = newWidth
        height = newHeight
    }

    func restart() {
        blobs = []
        shots = 0
        enterTimer = 0
        score = 0
        gains = []
        combo = 0
        biggest = 0
        danger = 0
        gameOver = false
        frame += 1
    }

    // MARK: - 上の列（細い筒の中で押し合う、本物のやわらかい玉）

    /// 撃った回数（はじめの 3 回は列に 1 個だけ。そのあと 4 個）
    private var shots = 0
    private var enterTimer: Double = 0
    /// 次はどちらの壁から入るか
    private var enterFromLeft = false
    /// 壁が白く光る（玉が入ってきたところ）：左・右
    private(set) var gateFlash: (left: Double, right: Double) = (0, 0)
    var queueCapacity: Int { shots < 3 ? 1 : 4 }
    /// 列の玉を押さえている間は、新しい玉を入れない
    var holding = false
    /// 筒の太さ（列の玉はこの高さにつぶれて、横に長くなる）
    var queueHeight: Float { width * 0.095 }
    var queueCount: Int { blobs.reduce(0) { $0 + ($1.queued ? 1 : 0) } }

    /// 列の玉（左から順）：id・数字の段階・横の位置
    func queueLayout() -> [(id: Int, level: Int, x: Float)] {
        blobs.filter(\.queued).map { ($0.id, $0.level, $0.center.x) }.sorted { $0.x < $1.x }
    }

    /// 指を置いた場所にいちばん近い列の玉（どれでも選んで撃てる）
    func queueBlob(near x: Float) -> Int? {
        queueLayout().min { abs($0.x - x) < abs($1.x - x) }?.id
    }

    /// 列の玉のいまの中心
    func launchPoint(_ id: Int) -> Vec {
        blobs.first { $0.id == id }?.center ?? Vec(width / 2, queueY)
    }

    /// 列に空きがあれば、左右の壁から交互に新しい玉が勢いよく飛びこんでくる（壁が白く光る）
    private func feedQueue(_ dt: Double) {
        enterTimer -= dt
        gateFlash.left = max(0, gateFlash.left - dt * 4)
        gateFlash.right = max(0, gateFlash.right - dt * 4)
        guard queueCount < queueCapacity, enterTimer <= 0, !holding else { return }
        enterTimer = 0.3
        let top = max(1, min(5, biggest - 3))
        var level = Int.random(in: 0...top)
        if Int.random(in: 0..<3) > 0 { level = min(level, Int.random(in: 0...1)) }
        // 筒に入りきる分だけ（つぶれたときの長さ ≒ 面積 ÷ 筒の太さ）
        let used = blobs.filter(\.queued).reduce(Float(0)) { $0 + $1.targetArea / (queueHeight * 1.1) }
        guard used + area(level) / (queueHeight * 1.1) < width * 0.85 else { return }
        enterFromLeft.toggle()
        let r = min(radius(level), queueHeight * 0.6)
        let x = enterFromLeft ? r + 1 : width - r - 1
        var blob = makeBlob(level: level, center: Vec(x, queueY))
        blob.queued = true
        blob.flash = 1
        let velocity = Vec(enterFromLeft ? width * 1.6 : -width * 1.6, 0)
        let step = Float(1.0 / 240)
        for index in blob.prev.indices { blob.prev[index] = blob.pos[index] - velocity * step }
        blobs.append(blob)
        if enterFromLeft { gateFlash.left = 1 } else { gateFlash.right = 1 }
    }

    /// 引っぱった長さと向きから、撃つ速さ（短いとそっと、長いと強く）
    func launchVelocity(drag: Vec) -> Vec {
        let length = simd_length(drag)
        guard length > 6 else { return Vec(0, 0) }
        let speed = min(length * 6, width * 3.2)
        return drag / length * speed
    }

    /// 選んだ列の玉を筒から放して、指の向きへ撃つ（drag は玉から指まで）
    func shoot(id: Int, drag: Vec) {
        guard !gameOver, let index = blobs.firstIndex(where: { $0.id == id && $0.queued }) else { return }
        blobs[index].queued = false
        blobs[index].age = 0
        let velocity = launchVelocity(drag: drag)
        let step = Float(1.0 / 240)
        for p in blobs[index].pos.indices { blobs[index].prev[p] = blobs[index].pos[p] - velocity * step }
        shots += 1
        enterTimer = max(enterTimer, 0.15)
        GameAudio.shared.play(.tap)
    }

    private func makeBlob(level: Int, center: Vec) -> Blob {
        let count = pointCount(level)
        let r = radius(level)
        var points: [Vec] = []
        for index in 0..<count {
            let angle = Float(index) / Float(count) * 2 * .pi
            points.append(center + Vec(cos(angle), sin(angle)) * r)
        }
        nextID += 1
        var blob = Blob(id: nextID, level: level, pos: points, prev: points, area: area(level), targetArea: area(level))
        blob.updateBounds()
        return blob
    }

    // MARK: - 毎コマ

    func step(_ dt: Double) {
        guard !gameOver else { return }
        accumulator += dt
        let tick = 1.0 / 240
        var steps = 0
        while accumulator >= tick, steps < 8 {
            physics(Float(tick))
            accumulator -= tick
            steps += 1
        }
        if steps == 8 { accumulator = 0 }
        for index in blobs.indices {
            blobs[index].age += dt
            // くっついた直後の大きさから、本来の大きさへ
            blobs[index].area += (blobs[index].targetArea - blobs[index].area) * Float(min(1, dt * 3))
        }
        feedQueue(dt)
        checkDanger(dt)
        for index in blobs.indices where blobs[index].flash > 0 {
            blobs[index].flash = max(0, blobs[index].flash - dt * 2.5)
        }
        for index in gains.indices { gains[index].life -= dt }
        gains.removeAll { $0.life <= 0 }
        comboTimer -= dt
        if comboTimer <= 0 { combo = 0 }
        frame &+= 1
    }

    private func physics(_ dt: Float) {
        let gravity = Vec(0, width * 2.6) * dt * dt
        // 前の動きを引きつぎ（少し弱めて）、重力で落とす
        for b in blobs.indices {
            if blobs[b].queued {
                // 筒の中：重力のかわりに筒の真ん中へ引かれ、押し合いながら落ち着く
                let center = blobs[b].center
                let pull = Vec((width / 2 - center.x) * 7, (queueY - center.y) * 60) * dt * dt
                for i in blobs[b].pos.indices {
                    let p = blobs[b].pos[i]
                    let velocity = (p - blobs[b].prev[i]) * 0.96
                    blobs[b].prev[i] = p
                    blobs[b].pos[i] = p + velocity + pull
                }
                continue
            }
            for i in blobs[b].pos.indices {
                let p = blobs[b].pos[i]
                let velocity = (p - blobs[b].prev[i]) * 0.994
                blobs[b].prev[i] = p
                blobs[b].pos[i] = p + velocity + gravity
            }
        }
        var touching: [(Int, Int)] = []
        for iteration in 0..<3 {
            for b in blobs.indices { keepShape(b) }
            for b in blobs.indices { blobs[b].updateBounds() }
            let pairs = collide(record: iteration == 2)
            if iteration == 2 { touching = pairs }
            for b in blobs.indices { walls(b) }
        }
        if !touching.isEmpty { merge(touching) }
    }

    /// まわりのばね（となり・ひとつ飛ばし）と、面積を保つ圧力
    private func keepShape(_ b: Int) {
        let count = blobs[b].pos.count
        let radius = sqrt(blobs[b].area / .pi)
        let edge = 2 * radius * sin(.pi / Float(count))
        let skip = 2 * radius * sin(2 * .pi / Float(count))
        for i in 0..<count {
            let j = (i + 1) % count
            let delta = blobs[b].pos[j] - blobs[b].pos[i]
            let length = max(simd_length(delta), 0.0001)
            let correction = delta * ((length - edge) / length * 0.5 * 0.35)
            blobs[b].pos[i] += correction
            blobs[b].pos[j] -= correction
            let k = (i + 2) % count
            let delta2 = blobs[b].pos[k] - blobs[b].pos[i]
            let length2 = max(simd_length(delta2), 0.0001)
            let correction2 = delta2 * ((length2 - skip) / length2 * 0.5 * 0.02)
            blobs[b].pos[i] += correction2
            blobs[b].pos[k] -= correction2
        }
        // 圧力：面積の差を、各点の「面積を増やす向き」に分ける
        let current = blobs[b].currentArea
        var gradients: [Vec] = []
        gradients.reserveCapacity(count)
        var sum: Float = 0
        for i in 0..<count {
            let before = blobs[b].pos[(i + count - 1) % count], after = blobs[b].pos[(i + 1) % count]
            let gradient = Vec(after.y - before.y, before.x - after.x) * 0.5
            gradients.append(gradient)
            sum += simd_length_squared(gradient)
        }
        guard sum > 0.0001 else { return }
        let lambda = (blobs[b].area - current) / sum * 0.4
        for i in 0..<count { blobs[b].pos[i] += gradients[i] * lambda }
    }

    /// 玉どうし：相手の中に入った点を、相手のいちばん近いふちまで押しもどす（相手のふちも半分押す）
    private func collide(record: Bool) -> [(Int, Int)] {
        var list: [(Int, Int)] = []
        let count = blobs.count
        for a in 0..<count {
            for b in (a + 1)..<count {
                guard blobs[a].maxX >= blobs[b].minX, blobs[b].maxX >= blobs[a].minX,
                      blobs[a].maxY >= blobs[b].minY, blobs[b].maxY >= blobs[a].minY else { continue }
                let hitA = push(points: a, into: b)
                let hitB = push(points: b, into: a)
                if record, hitA || hitB, blobs[a].level == blobs[b].level, blobs[a].age > 0.15, blobs[b].age > 0.15 {
                    list.append((a, b))
                }
            }
        }
        return list
    }

    @discardableResult
    private func push(points a: Int, into b: Int) -> Bool {
        var hit = false
        let countB = blobs[b].pos.count
        for i in blobs[a].pos.indices {
            let p = blobs[a].pos[i]
            guard blobs[b].contains(p) else { continue }
            hit = true
            // いちばん近いふち
            var bestDistance = Float.infinity
            var bestEdge = 0
            var bestT: Float = 0
            var bestPoint = p
            for j in 0..<countB {
                let e0 = blobs[b].pos[j], e1 = blobs[b].pos[(j + 1) % countB]
                let edge = e1 - e0
                let t = min(max(simd_dot(p - e0, edge) / max(simd_length_squared(edge), 0.0001), 0), 1)
                let q = e0 + edge * t
                let distance = simd_length_squared(q - p)
                if distance < bestDistance {
                    bestDistance = distance
                    bestEdge = j
                    bestT = t
                    bestPoint = q
                }
            }
            var move = bestPoint - p
            let length = simd_length(move)
            // 一度に大きく動かしすぎない（はじけ飛ばないように）
            let limit = width * 0.03
            if length > limit { move *= limit / length }
            blobs[a].pos[i] += move * 0.5
            // 押されている点は少しすべりにくく（止まったあとにぷるぷる震え続けないように）
            let previous = blobs[a].prev[i]
            blobs[a].prev[i] = previous + (blobs[a].pos[i] - previous) * 0.08
            let next = (bestEdge + 1) % countB
            blobs[b].pos[bestEdge] -= move * 0.5 * (1 - bestT)
            blobs[b].pos[next] -= move * 0.5 * bestT
        }
        if hit { blobs[b].updateBounds() }
        return hit
    }

    /// 容器の壁：左右・底・下の斜めの角・左右の半円の出っぱり（さわると少しすべりにくくする）
    private func walls(_ b: Int) {
        if blobs[b].queued {
            // 筒の上下と左右の壁（つぶれて横に長くなる）
            let half = queueHeight * 0.55
            for i in blobs[b].pos.indices {
                var p = blobs[b].pos[i]
                p.x = min(max(p.x, 0), width)
                p.y = min(max(p.y, queueY - half), queueY + half)
                blobs[b].pos[i] = p
            }
            return
        }
        let w = width, h = height, c = chamfer
        let bumperL = Vec(0, bumperY), bumperR = Vec(w, bumperY)
        let radius = bumperRadius
        for i in blobs[b].pos.indices {
            var p = blobs[b].pos[i]
            var touched = false
            if p.x < 0 { p.x = 0; touched = true }
            if p.x > w { p.x = w; touched = true }
            if p.y > h { p.y = h; touched = true }
            // 左下の斜め：x - y >= c - h
            let left = (p.x - p.y) - (c - h)
            if left < 0 {
                p += Vec(1, -1) * (-left / 2)
                touched = true
            }
            // 右下の斜め：-x - y >= c - h - w
            let right = (-p.x - p.y) - (c - h - w)
            if right < 0 {
                p += Vec(-1, -1) * (-right / 2)
                touched = true
            }
            for bumper in [bumperL, bumperR] {
                let offset = p - bumper
                let distance = simd_length(offset)
                if distance < radius, distance > 0.0001 {
                    p = bumper + offset / distance * radius
                    touched = true
                }
            }
            if touched {
                // さわっているところは横の動きを少しおさえる
                let previous = blobs[b].prev[i]
                blobs[b].prev[i] = previous + (p - previous) * 0.15
            }
            blobs[b].pos[i] = p
        }
    }

    // MARK: - くっつく

    private func merge(_ pairs: [(Int, Int)]) {
        var used = Set<Int>()
        var removed = Set<Int>()
        var born: [Blob] = []
        for (a, b) in pairs where !used.contains(a) && !used.contains(b) {
            used.insert(a)
            used.insert(b)
            removed.insert(a)
            removed.insert(b)
            let first = blobs[a], second = blobs[b]
            let areaA = max(first.currentArea, 1), areaB = max(second.currentArea, 1)
            let center = (first.center * areaA + second.center * areaB) / (areaA + areaB)
            let level = first.level + 1
            // 2 つの玉を合わせた外形を、中心から見た角度ごとに測って、新しい玉の形にする（まわりに食いこまない）
            let count = pointCount(level)
            let all = first.pos + second.pos
            var radii = [Float](repeating: 0, count: count)
            for p in all {
                let offset = p - center
                var angle = atan2(offset.y, offset.x)
                if angle < 0 { angle += 2 * .pi }
                let slot = Int((angle / (2 * .pi) * Float(count)).rounded()) % count
                radii[slot] = max(radii[slot], simd_length(offset))
            }
            let average = radii.filter { $0 > 0 }.reduce(0, +) / Float(max(radii.filter { $0 > 0 }.count, 1))
            var points: [Vec] = []
            for index in 0..<count {
                let angle = Float(index) / Float(count) * 2 * .pi
                let r = radii[index] > 0 ? radii[index] : average
                points.append(center + Vec(cos(angle), sin(angle)) * r)
            }
            nextID += 1
            var blob = Blob(id: nextID, level: level, pos: points, prev: points, area: areaA + areaB, targetArea: area(level))
            blob.age = 0.05
            blob.flash = 1
            // 列の玉にぶつけてくっついたら、そのまま列（筒）の中に残る
            blob.queued = first.queued || second.queued
            // 点数：生まれた玉の数字
            score += blob.value
            nextID += 1
            gains.append(Gain(id: nextID, text: "+\(blob.value)", life: 1.6))
            if gains.count > 6 { gains.removeFirst(gains.count - 6) }
            combo = comboTimer > 0 ? combo + 1 : 1
            comboTimer = 1.0
            if combo == 3 { amass += 1 }
            blob.updateBounds()
            born.append(blob)
            biggest = max(biggest, level)
            haptic.impactOccurred(intensity: min(0.4 + CGFloat(level) * 0.05, 1))
            GameAudio.shared.play(.pop(combo: min(level / 2 + 1, 6)))
            unlock(level: level)
        }
        blobs = blobs.enumerated().filter { !removed.contains($0.offset) }.map(\.element) + born
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: "puniBest2")
        }
        // 1024 が 3 つ
        if blobs.filter({ $0.level == 10 }).count >= 3 { achieve("3x 1024") }
    }

    private func unlock(level: Int) {
        if [6, 8, 10, 11, 12, 13].contains(level) { achieve("\(1 << level)") }
    }

    private func achieve(_ name: String) {
        guard !achieved.contains(name) else { return }
        achieved.insert(name)
        UserDefaults.standard.set(Array(achieved), forKey: "puniAchievements")
        nextID += 1
        popup = Popup(id: nextID, text: name)
        GameAudio.shared.play(.win)
    }

    private func checkDanger(_ dt: Double) {
        // 左右の半円の出っぱりより上まで積み上がると危ない（2 秒で終わり）
        let over = blobs.contains { !$0.queued && $0.age > 1.5 && $0.minY < bumperY }
        danger = over ? min(danger + dt / 2, 1) : max(0, danger - dt / 2)
        if danger >= 1 {
            gameOver = true
            GameAudio.shared.play(.lose)
        }
    }
}
