import SwiftUI
import UIKit

/// 「ぷにぷにシューター」のルールと物理。
/// びんの上の発射台から、ぷにぷにの玉をねらって撃つ。同じ色（同じ大きさ）の玉がさわるとくっついて、ひとつ大きな玉になる。
/// いちばん大きな玉どうしがくっつくと、はじけて大きな得点。玉が赤い線より上に 3 秒いると終わり。
/// 玉は円として動かすが、押し合うと少し重なるようにして、重なったぶん描くときにへこませる（ぷにっとつぶれて見える）
@MainActor
final class PuniGame: ObservableObject {
    struct Blob: Identifiable {
        let id: Int
        var level: Int
        var pos: CGPoint
        var vel: CGVector = .zero
        /// いまの半径（くっついて生まれたときは少し小さく、すぐ本来の大きさへふくらむ）
        var radius: CGFloat
        /// ぷるぷる（ばねで揺れる。押されたり当たったりすると大きくなる）
        var squash: CGFloat = 0
        var squashVel: CGFloat = 0
        var squashAngle: CGFloat = 0
        /// 押し合っている向きと深さ（描くときにへこませる）
        var contacts: [(angle: CGFloat, depth: CGFloat)] = []
        var age: Double = 0
        /// 撃ったばかり（まだ何にもさわっていない）。赤い線を通っても数えない
        var fresh = true
        /// まばたきの時計
        var blink: Double = .random(in: 0...4)
    }

    struct Particle: Identifiable {
        let id: Int
        var pos: CGPoint
        var vel: CGVector
        var life: Double
        var size: CGFloat
        var color: Color
    }

    struct Floater: Identifiable {
        let id: Int
        var pos: CGPoint
        var text: String
        var life: Double
        var big: Bool
    }

    /// 玉の段階（0 がいちばん小さい）
    static let levels = 11
    /// 段階ごとの半径（びんの幅 360 のとき）
    static let radii: [CGFloat] = [14, 19, 25, 31, 38, 46, 55, 65, 76, 88, 100]
    static let colors: [Color] = [
        Color(red: 1.0, green: 0.55, blue: 0.62), Color(red: 1.0, green: 0.72, blue: 0.35), Color(red: 1.0, green: 0.86, blue: 0.3),
        Color(red: 0.62, green: 0.88, blue: 0.4), Color(red: 0.35, green: 0.82, blue: 0.7), Color(red: 0.4, green: 0.7, blue: 1.0),
        Color(red: 0.58, green: 0.55, blue: 1.0), Color(red: 0.82, green: 0.5, blue: 0.95), Color(red: 1.0, green: 0.5, blue: 0.82),
        Color(red: 0.98, green: 0.42, blue: 0.4), Color(red: 1.0, green: 0.78, blue: 0.25),
    ]

    @Published private(set) var frame = 0
    @Published private(set) var score = 0
    @Published private(set) var best = UserDefaults.standard.integer(forKey: "puniBest")
    @Published private(set) var gameOver = false
    /// いちばん大きくなった段階
    @Published private(set) var maxLevel = 0
    /// 発射台にのっている玉と、その次の玉
    @Published private(set) var current = 0
    @Published private(set) var next = 1

    private(set) var blobs: [Blob] = []
    private(set) var particles: [Particle] = []
    private(set) var floaters: [Floater] = []
    /// びんの大きさ（画面に合わせて決める）
    private(set) var size = CGSize(width: 360, height: 500)
    /// 赤い線（これより上に 3 秒いると終わり）の高さ
    var dangerY: CGFloat { size.height * 0.17 }
    /// 発射台の場所
    var launcher: CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.07) }
    /// 赤い線を越えている時間（0〜3）
    private(set) var danger: Double = 0
    /// 画面のゆれ
    private(set) var shake: CGFloat = 0
    private var cooldown: Double = 0
    private var combo = 0
    private var comboTimer: Double = 0
    private var nextID = 0
    private var accumulator: Double = 0
    private let haptic = UIImpactFeedbackGenerator(style: .soft)
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)

    init() {
        current = Int.random(in: 0...1)
        next = Int.random(in: 0...2)
    }

    var scale: CGFloat { size.width / 360 }

    func radius(_ level: Int) -> CGFloat { Self.radii[min(max(level, 0), Self.levels - 1)] * scale }

    /// 画面の大きさに合わせて、びんの大きさを決める（玉の位置も一緒に伸び縮みさせる）
    func layout(_ newSize: CGSize) {
        guard newSize.width > 50, abs(newSize.width - size.width) > 0.5 || abs(newSize.height - size.height) > 0.5 else { return }
        let sx = newSize.width / size.width, sy = newSize.height / size.height
        for index in blobs.indices {
            blobs[index].pos.x *= sx
            blobs[index].pos.y *= sy
            blobs[index].radius *= sx
        }
        size = newSize
    }

    func restart() {
        blobs = []
        particles = []
        floaters = []
        score = 0
        maxLevel = 0
        danger = 0
        combo = 0
        gameOver = false
        current = Int.random(in: 0...1)
        next = Int.random(in: 0...2)
        frame += 1
    }

    // MARK: - 撃つ

    /// 指の場所へ向けた、撃つ速さ（向きは発射台から指へ。上向きには撃てない）
    func shotVelocity(toward point: CGPoint) -> CGVector? {
        let dx = point.x - launcher.x, dy = point.y - launcher.y
        let length = hypot(dx, dy)
        guard length > 12, dy > -length * 0.25 else { return nil }
        let speed = min(max(length * 3.2, 380), 1250) * scale
        return CGVector(dx: dx / length * speed, dy: dy / length * speed)
    }

    /// 撃ったあとの道すじ（ねらいの点線。ほかの玉は気にしない）
    func trajectory(toward point: CGPoint) -> [CGPoint] {
        guard let velocity = shotVelocity(toward: point) else { return [] }
        var pos = launcher, vel = velocity
        var points: [CGPoint] = []
        let r = radius(current)
        for _ in 0..<26 {
            for _ in 0..<4 {
                let dt = 1.0 / 120
                vel.dy += gravity * dt
                pos.x += vel.dx * dt
                pos.y += vel.dy * dt
                if pos.x < r { pos.x = r; vel.dx = -vel.dx * 0.4 }
                if pos.x > size.width - r { pos.x = size.width - r; vel.dx = -vel.dx * 0.4 }
            }
            if pos.y > size.height - r { break }
            points.append(pos)
        }
        return points
    }

    func shoot(toward point: CGPoint) {
        guard !gameOver, cooldown <= 0, let velocity = shotVelocity(toward: point) else { return }
        var blob = Blob(id: makeID(), level: current, pos: launcher, radius: radius(current))
        blob.vel = velocity
        blob.squash = 0.18
        blob.squashAngle = atan2(velocity.dy, velocity.dx)
        blobs.append(blob)
        current = next
        // 次の玉：いままで作った大きさに合わせて、小さめの玉からえらぶ
        let top = min(4, max(1, maxLevel - 1))
        next = Int.random(in: 0...top)
        if Int.random(in: 0..<3) == 0 { next = min(next, 1) }
        cooldown = 0.45
        GameAudio.shared.play(.tap)
    }

    // MARK: - 毎コマ

    private var gravity: CGFloat { 1500 * scale }

    func step(_ dt: Double) {
        guard !gameOver else { return }
        cooldown -= dt
        comboTimer -= dt
        if comboTimer <= 0 { combo = 0 }
        accumulator += dt
        // 決まった細かさで動かす（重なり方がコマの長さで変わらないように）
        let tick = 1.0 / 240
        var steps = 0
        while accumulator >= tick, steps < 12 {
            physics(tick)
            accumulator -= tick
            steps += 1
        }
        if steps == 12 { accumulator = 0 }
        animate(dt)
        checkDanger(dt)
        frame &+= 1
    }

    private func physics(_ dt: Double) {
        let g = gravity
        for index in blobs.indices {
            blobs[index].vel.dy += g * dt
            blobs[index].vel.dx *= 0.9995
            blobs[index].pos.x += blobs[index].vel.dx * dt
            blobs[index].pos.y += blobs[index].vel.dy * dt
            blobs[index].contacts.removeAll(keepingCapacity: true)
        }
        // びんの壁と底
        for index in blobs.indices {
            let r = blobs[index].radius
            if blobs[index].pos.x < r {
                bump(index, impact: abs(blobs[index].vel.dx), angle: .pi)
                blobs[index].pos.x = r
                blobs[index].vel.dx = abs(blobs[index].vel.dx) * 0.3
            }
            if blobs[index].pos.x > size.width - r {
                bump(index, impact: abs(blobs[index].vel.dx), angle: 0)
                blobs[index].pos.x = size.width - r
                blobs[index].vel.dx = -abs(blobs[index].vel.dx) * 0.3
            }
            if blobs[index].pos.y > size.height - r {
                bump(index, impact: abs(blobs[index].vel.dy), angle: .pi / 2)
                blobs[index].pos.y = size.height - r
                blobs[index].vel.dy = -abs(blobs[index].vel.dy) * 0.2
                blobs[index].vel.dx *= 0.98
                blobs[index].fresh = false
                blobs[index].contacts.append((.pi / 2, 0))
            }
        }
        // 玉どうし：やわらかく押し返す（少し重なったままにして、ぷにっと見せる）
        var merges: [(Int, Int)] = []
        var merging = Set<Int>()
        let count = blobs.count
        for i in 0..<count {
            for j in (i + 1)..<count {
                let dx = blobs[j].pos.x - blobs[i].pos.x, dy = blobs[j].pos.y - blobs[i].pos.y
                let minDistance = blobs[i].radius + blobs[j].radius
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared < minDistance * minDistance else { continue }
                let distance = max(sqrt(distanceSquared), 0.001)
                let nx = dx / distance, ny = dy / distance
                let overlap = minDistance - distance
                // 同じ段階どうしはくっつく
                if blobs[i].level == blobs[j].level, !merging.contains(i), !merging.contains(j), blobs[i].age > 0.05, blobs[j].age > 0.05 {
                    merges.append((i, j))
                    merging.insert(i)
                    merging.insert(j)
                    continue
                }
                let mi = blobs[i].radius * blobs[i].radius, mj = blobs[j].radius * blobs[j].radius
                let total = mi + mj
                // 重なりの 3 割ずつ押しもどす（残りがへこみになる）
                let push = overlap * 0.3
                blobs[i].pos.x -= nx * push * mj / total
                blobs[i].pos.y -= ny * push * mj / total
                blobs[j].pos.x += nx * push * mi / total
                blobs[j].pos.y += ny * push * mi / total
                // 近づく速さを打ち消し、少しはね返す
                let rvx = blobs[j].vel.dx - blobs[i].vel.dx, rvy = blobs[j].vel.dy - blobs[i].vel.dy
                let along = rvx * nx + rvy * ny
                if along < 0 {
                    let impulse = -(1 + 0.12) * along / (1 / mi + 1 / mj)
                    blobs[i].vel.dx -= impulse / mi * nx
                    blobs[i].vel.dy -= impulse / mi * ny
                    blobs[j].vel.dx += impulse / mj * nx
                    blobs[j].vel.dy += impulse / mj * ny
                    // 横すべりを少しおさえる（積み上がるように）
                    let tx = -ny, ty = nx
                    let slide = rvx * tx + rvy * ty
                    let friction = slide * 0.04
                    blobs[i].vel.dx += friction * tx * mj / total
                    blobs[i].vel.dy += friction * ty * mj / total
                    blobs[j].vel.dx -= friction * tx * mi / total
                    blobs[j].vel.dy -= friction * ty * mi / total
                    if -along > 120 * scale {
                        bump(i, impact: -along * 0.5, angle: atan2(ny, nx))
                        bump(j, impact: -along * 0.5, angle: atan2(-ny, -nx))
                    }
                }
                let depth = overlap * 0.5
                blobs[i].contacts.append((atan2(ny, nx), depth))
                blobs[j].contacts.append((atan2(-ny, -nx), depth))
                blobs[i].fresh = false
                blobs[j].fresh = false
            }
        }
        if !merges.isEmpty { merge(merges) }
    }

    /// 当たったときのぷるん
    private func bump(_ index: Int, impact: CGFloat, angle: CGFloat) {
        let amount = min(impact / (1400 * scale), 0.28)
        guard amount > 0.02 else { return }
        if amount > abs(blobs[index].squash) {
            blobs[index].squash = amount
            blobs[index].squashAngle = angle
        }
    }

    private func merge(_ pairs: [(Int, Int)]) {
        var removed = Set<Int>()
        var born: [Blob] = []
        for (i, j) in pairs {
            let a = blobs[i], b = blobs[j]
            removed.insert(i)
            removed.insert(j)
            let level = a.level + 1
            let center = CGPoint(x: (a.pos.x + b.pos.x) / 2, y: (a.pos.y + b.pos.y) / 2)
            combo = comboTimer > 0 ? combo + 1 : 1
            comboTimer = 1.2
            if level >= Self.levels {
                // いちばん大きな玉どうし：はじけて消える
                let points = 5_000 * combo
                score += points
                burst(at: center, color: Self.colors[Self.levels - 1], count: 60, speed: 600)
                floater("+\(points)", at: center, big: true)
                shake = 18 * scale
                heavyHaptic.impactOccurred()
                GameAudio.shared.play(.bomb)
                continue
            }
            var blob = Blob(id: makeID(), level: level, pos: center, radius: max(a.radius, b.radius) * 1.05)
            blob.vel = CGVector(dx: (a.vel.dx + b.vel.dx) / 2, dy: min((a.vel.dy + b.vel.dy) / 2, 0) - 120 * scale)
            blob.squash = 0.3
            blob.squashAngle = .pi / 2
            blob.fresh = false
            blob.age = 0.06
            born.append(blob)
            let points = (level + 1) * (level + 2) * 5 * combo
            score += points
            burst(at: center, color: Self.colors[level], count: 10 + level * 3, speed: 220 + CGFloat(level) * 30)
            floater(combo > 1 ? "+\(points) ×\(combo)" : "+\(points)", at: center, big: level >= 7)
            if level > maxLevel {
                maxLevel = level
                if level >= 5 { floater("NEW!", at: CGPoint(x: center.x, y: center.y - radius(level) - 10 * scale), big: true) }
            }
            if level >= 6 { shake = max(shake, CGFloat(level) * 1.5 * scale) }
            haptic.impactOccurred(intensity: min(0.4 + CGFloat(level) * 0.06, 1))
            GameAudio.shared.play(.pop(combo: combo))
        }
        blobs = blobs.enumerated().filter { !removed.contains($0.offset) }.map(\.element) + born
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: "puniBest")
        }
    }

    /// ぷるぷる・ふくらみ・粒・文字を動かす
    private func animate(_ dt: Double) {
        for index in blobs.indices {
            blobs[index].age += dt
            if blobs[index].age > 1.5 { blobs[index].fresh = false }
            let target = radius(blobs[index].level)
            blobs[index].radius += (target - blobs[index].radius) * CGFloat(min(1, dt * 10))
            // ばね：ぷるん、ぷるんと揺れて止まる
            let k: CGFloat = 220, damping: CGFloat = 9
            blobs[index].squashVel += (-k * blobs[index].squash - damping * blobs[index].squashVel) * CGFloat(dt)
            blobs[index].squash += blobs[index].squashVel * CGFloat(dt)
            blobs[index].blink -= dt
            if blobs[index].blink < -0.12 { blobs[index].blink = .random(in: 2...5) }
        }
        for index in particles.indices {
            particles[index].vel.dy += 900 * scale * dt
            particles[index].pos.x += particles[index].vel.dx * dt
            particles[index].pos.y += particles[index].vel.dy * dt
            particles[index].life -= dt
        }
        particles.removeAll { $0.life <= 0 }
        for index in floaters.indices {
            floaters[index].pos.y -= 50 * scale * dt
            floaters[index].life -= dt
        }
        floaters.removeAll { $0.life <= 0 }
        shake *= CGFloat(max(0, 1 - dt * 10))
    }

    private func checkDanger(_ dt: Double) {
        let over = blobs.contains { !$0.fresh && $0.pos.y - $0.radius < dangerY && abs($0.vel.dy) < 300 * scale }
        danger = over ? danger + dt : max(0, danger - dt * 2)
        if danger >= 3 {
            gameOver = true
            heavyHaptic.impactOccurred()
            GameAudio.shared.play(.lose)
        }
    }

    private func burst(at point: CGPoint, color: Color, count: Int, speed: CGFloat) {
        for _ in 0..<count {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let velocity = CGFloat.random(in: 0.3...1) * speed * scale
            particles.append(Particle(id: makeID(), pos: point,
                                      vel: CGVector(dx: cos(angle) * velocity, dy: sin(angle) * velocity - 150 * scale),
                                      life: .random(in: 0.4...0.8), size: .random(in: 3...7) * scale, color: color))
        }
    }

    private func floater(_ text: String, at point: CGPoint, big: Bool) {
        floaters.append(Floater(id: makeID(), pos: point, text: text, life: 0.9, big: big))
    }

    private func makeID() -> Int {
        nextID += 1
        return nextID
    }

    /// 赤い線の危なさ（0〜1）
    var dangerLevel: Double { min(danger / 3, 1) }
}
