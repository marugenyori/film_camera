import SwiftUI

/// 「ぷにぷにシューター」の画面：上に得点と次の玉、まんなかにびん。びんの中をなぞってねらい、指をはなすと撃つ
struct PuniGameView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var game = PuniGame()
    @State private var aim: CGPoint?
    @State private var ticker: MartTicker?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1, green: 0.96, blue: 0.9), Color(red: 1, green: 0.88, blue: 0.9)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                header
                GeometryReader { geo in
                    let width = min(geo.size.width - 24, 440)
                    let height = min(geo.size.height - 8, width * 1.5)
                    PuniBoard(game: game, aim: aim)
                        .frame(width: width, height: height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { aim = $0.location }
                                .onEnded { value in
                                    game.shoot(toward: value.location)
                                    aim = nil
                                }
                        )
                        .onAppear { game.layout(CGSize(width: width, height: height)) }
                        .onChange(of: CGSize(width: width, height: height)) { _, size in game.layout(size) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("びんの中をなぞってねらい、指をはなして撃つ。同じ色がくっつくと大きくなる")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
            }
            if game.gameOver { gameOverCard }
        }
        .animation(.spring(duration: 0.4, bounce: 0.35), value: game.gameOver)
        .statusBarHidden()
        .onAppear {
            let model = game
            let ticker = MartTicker { [weak model] dt in
                MainActor.assumeIsolated { model?.step(dt) }
            }
            ticker.start()
            self.ticker = ticker
        }
        .onDisappear {
            ticker?.stop()
            ticker = nil
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.4))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.8), in: Circle())
            }
            .accessibilityLabel("やめる")
            VStack(alignment: .leading, spacing: 0) {
                Text("\(game.score)")
                    .font(.system(size: 30, weight: .black, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: game.score)
                Text("ベスト \(game.best)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color(red: 0.35, green: 0.25, blue: 0.3))
            Spacer()
            // 次の玉
            VStack(spacing: 2) {
                Text("つぎ")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(PuniGame.colors[game.next].gradient)
                    .frame(width: 22 + CGFloat(game.next) * 5, height: 22 + CGFloat(game.next) * 5)
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            // ここまで作った大きさ
            VStack(spacing: 2) {
                Text("最大")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(PuniGame.colors[game.maxLevel].gradient)
                    .frame(width: 30, height: 30)
                    .overlay(Text("\(game.maxLevel + 1)").font(.caption.weight(.black)).foregroundStyle(.white))
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private var gameOverCard: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("あふれちゃった！")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                Text("\(game.score)")
                    .font(.system(size: 48, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.55))
                Text(game.score >= game.best && game.score > 0 ? "ベスト更新！" : "ベスト \(game.best)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Button {
                    game.restart()
                } label: {
                    Text("もう一回")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 200, height: 52)
                        .background(Capsule().fill(Color(red: 1, green: 0.5, blue: 0.6)))
                }
                .buttonStyle(.plain)
                Button("やめる") { dismiss() }
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color(red: 0.35, green: 0.25, blue: 0.3))
            .padding(30)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white))
            .padding(30)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }
}

/// びんの中を描く（毎コマ描き直す）
private struct PuniBoard: View {
    @ObservedObject var game: PuniGame
    let aim: CGPoint?

    var body: some View {
        Canvas { context, size in
            _ = game.frame
            let shake = game.shake
            if shake > 0.5 {
                context.translateBy(x: .random(in: -shake...shake), y: .random(in: -shake...shake))
            }
            drawJar(&context, size)
            drawLauncher(&context)
            for blob in game.blobs { drawBlob(&context, blob) }
            for particle in game.particles {
                let rect = CGRect(x: particle.pos.x - particle.size / 2, y: particle.pos.y - particle.size / 2,
                                  width: particle.size, height: particle.size)
                context.opacity = min(1, particle.life * 2)
                context.fill(Path(ellipseIn: rect), with: .color(particle.color))
            }
            context.opacity = 1
            for floater in game.floaters {
                context.opacity = min(1, floater.life * 2.5)
                let text = Text(floater.text)
                    .font(.system(size: (floater.big ? 26 : 17) * game.scale, weight: .black, design: .rounded))
                    .foregroundStyle(floater.big ? Color(red: 1, green: 0.4, blue: 0.5) : Color(red: 0.4, green: 0.3, blue: 0.35))
                context.draw(text, at: floater.pos)
            }
            context.opacity = 1
        }
    }

    private func drawJar(_ context: inout GraphicsContext, _ size: CGSize) {
        let jar = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 26)
        context.fill(jar, with: .color(.white.opacity(0.6)))
        context.stroke(jar, with: .color(Color(red: 0.95, green: 0.75, blue: 0.8)), lineWidth: 3)
        // 赤い線（越えていると点滅して濃くなる）
        var line = Path()
        line.move(to: CGPoint(x: 10, y: game.dangerY))
        line.addLine(to: CGPoint(x: size.width - 10, y: game.dangerY))
        let level = game.dangerLevel
        let blinkOn = level > 0 && Int(Date().timeIntervalSinceReferenceDate * (4 + level * 8)) % 2 == 0
        context.stroke(line, with: .color(Color(red: 1, green: 0.3, blue: 0.35).opacity(0.35 + (blinkOn ? 0.6 : 0.2 * level))),
                       style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
    }

    private func drawLauncher(_ context: inout GraphicsContext) {
        let center = game.launcher
        // ねらいの点線
        if let aim, !game.gameOver {
            let points = game.trajectory(toward: aim)
            for (index, point) in points.enumerated() {
                let r = max(1.5, 4 - CGFloat(index) * 0.1) * game.scale
                context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                             with: .color(Color(red: 0.6, green: 0.45, blue: 0.5).opacity(0.5 - Double(index) * 0.015)))
            }
        }
        // 発射台の台座と、のっている玉
        let base = CGRect(x: center.x - 30 * game.scale, y: center.y - 6 * game.scale, width: 60 * game.scale, height: 12 * game.scale)
        context.fill(Path(roundedRect: base.offsetBy(dx: 0, dy: game.radius(game.current) + 2), cornerRadius: 6),
                     with: .color(Color(red: 0.95, green: 0.75, blue: 0.8)))
        var preview = PuniGame.Blob(id: -1, level: game.current, pos: center, radius: game.radius(game.current))
        preview.fresh = true
        drawBlob(&context, preview)
    }

    /// ぷにぷにの玉：押されているところはへこみ、ぷるぷる揺れる。顔つき
    private func drawBlob(_ context: inout GraphicsContext, _ blob: PuniGame.Blob) {
        let r = blob.radius
        let center = blob.pos
        let time = Date().timeIntervalSinceReferenceDate
        let count = 36
        var points: [CGPoint] = []
        var squeeze: CGFloat = 0
        for contact in blob.contacts { squeeze += contact.depth }
        for index in 0..<count {
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
            var radius = r * (1 - blob.squash * cos(2 * (angle - blob.squashAngle)))
            radius += r * 0.012 * sin(3 * angle + CGFloat(time) * 4 + CGFloat(blob.id))
            for contact in blob.contacts {
                let facing = cos(angle - contact.angle)
                if facing > 0 { radius -= contact.depth * 1.4 * pow(facing, 3) }
            }
            points.append(CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        }
        // 点のあいだをなめらかにつなぐ
        var shape = Path()
        let first = CGPoint(x: (points[count - 1].x + points[0].x) / 2, y: (points[count - 1].y + points[0].y) / 2)
        shape.move(to: first)
        for index in 0..<count {
            let point = points[index], following = points[(index + 1) % count]
            shape.addQuadCurve(to: CGPoint(x: (point.x + following.x) / 2, y: (point.y + following.y) / 2), control: point)
        }
        shape.closeSubpath()
        let color = PuniGame.colors[blob.level]
        // 影
        context.fill(shape.offsetBy(dx: 0, dy: r * 0.08), with: .color(.black.opacity(0.08)))
        context.fill(shape, with: .color(color))
        // 左上を明るく（白から透明へのぼかしを重ねる）
        context.fill(shape, with: .radialGradient(Gradient(colors: [.white.opacity(0.5), .white.opacity(0)]),
                                                   center: CGPoint(x: center.x - r * 0.35, y: center.y - r * 0.4),
                                                   startRadius: r * 0.05, endRadius: r * 1.1))
        context.stroke(shape, with: .color(color), lineWidth: max(1.2, r * 0.05))
        context.stroke(shape, with: .color(.black.opacity(0.16)), lineWidth: max(1.2, r * 0.05))
        // つやの光
        let shine = CGRect(x: center.x - r * 0.55, y: center.y - r * 0.62, width: r * 0.42, height: r * 0.26)
        context.fill(Path(ellipseIn: shine), with: .color(.white.opacity(0.55)))
        // 顔（押されてつぶれていると、ぎゅっと目をつぶる）
        let ink = Color(red: 0.25, green: 0.15, blue: 0.2)
        let eyeY = center.y - r * 0.02
        let squished = squeeze > r * 0.18
        for side in [-1.0, 1.0] as [CGFloat] {
            let eye = CGPoint(x: center.x + side * r * 0.3, y: eyeY)
            if blob.blink < 0 || squished {
                var lid = Path()
                if squished {
                    lid.move(to: CGPoint(x: eye.x - r * 0.09 * side, y: eye.y - r * 0.07))
                    lid.addLine(to: CGPoint(x: eye.x + r * 0.06 * side, y: eye.y))
                    lid.addLine(to: CGPoint(x: eye.x - r * 0.09 * side, y: eye.y + r * 0.07))
                } else {
                    lid.move(to: CGPoint(x: eye.x - r * 0.09, y: eye.y))
                    lid.addLine(to: CGPoint(x: eye.x + r * 0.09, y: eye.y))
                }
                context.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: max(1.2, r * 0.06), lineCap: .round, lineJoin: .round))
            } else {
                let size = r * 0.17
                context.fill(Path(ellipseIn: CGRect(x: eye.x - size / 2, y: eye.y - size * 0.6, width: size, height: size * 1.2)),
                             with: .color(ink))
                context.fill(Path(ellipseIn: CGRect(x: eye.x - size * 0.05, y: eye.y - size * 0.45, width: size * 0.4, height: size * 0.4)),
                             with: .color(.white))
            }
            // ほっぺ
            context.fill(Path(ellipseIn: CGRect(x: eye.x + side * r * 0.08 - r * 0.1, y: eye.y + r * 0.14, width: r * 0.2, height: r * 0.1)),
                         with: .color(Color(red: 1, green: 0.4, blue: 0.5).opacity(0.35)))
        }
        var mouth = Path()
        let mouthY = center.y + r * 0.2
        if blob.level >= 6 {
            // 大きな玉は口をあけてにっこり
            mouth.move(to: CGPoint(x: center.x - r * 0.12, y: mouthY))
            mouth.addQuadCurve(to: CGPoint(x: center.x + r * 0.12, y: mouthY), control: CGPoint(x: center.x, y: mouthY + r * 0.2))
            mouth.closeSubpath()
            context.fill(mouth, with: .color(ink))
        } else {
            mouth.move(to: CGPoint(x: center.x - r * 0.1, y: mouthY))
            mouth.addQuadCurve(to: CGPoint(x: center.x + r * 0.1, y: mouthY), control: CGPoint(x: center.x, y: mouthY + r * 0.12))
            context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: max(1, r * 0.05), lineCap: .round))
        }
    }
}
