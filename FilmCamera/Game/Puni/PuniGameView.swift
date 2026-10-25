import SwiftUI

/// 「ぷにぷにシューター」の画面（sobosuba の見た目にそろえる）：暗い灰色の背景、灰色のわくの黒い容器、
/// 上に次の玉の列、大きな灰色の点数。列のどの玉でも、近くに指を置いて引っぱると選んだ玉から指へ矢印が出て、はなすとその向きに撃つ
struct PuniGameView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var game = PuniGame()
    /// 選んだ列の玉と、指の場所（容器の中の座標）
    @State private var picked: Int?
    @State private var finger: CGPoint?
    @State private var amassShown = false
    @State private var ticker: MartTicker?
    @State private var showingMenu = false

    var body: some View {
        ZStack {
            Color(white: 0.1).ignoresSafeArea()
            VStack(spacing: 6) {
                header
                GeometryReader { geo in
                    let outer = min(geo.size.width - 16, geo.size.height / PuniBoard.heightRatio)
                    let inner = PuniBoard.innerRect(outer: outer)
                    PuniBoard(game: game, picked: picked, finger: finger)
                        .frame(width: outer, height: outer * PuniBoard.heightRatio)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let point = CGPoint(x: value.location.x - inner.minX, y: value.location.y - inner.minY)
                                    if picked == nil {
                                        // 指を置いた場所にいちばん近い列の玉を選ぶ
                                        picked = game.queueIndex(near: Float(value.startLocation.x - inner.minX))
                                    }
                                    finger = point
                                }
                                .onEnded { value in
                                    if let index = picked {
                                        let origin = game.launchPoint(index)
                                        let point = CGPoint(x: value.location.x - inner.minX, y: value.location.y - inner.minY)
                                        game.shoot(index: index, drag: PuniGame.Vec(Float(point.x) - origin.x, Float(point.y) - origin.y))
                                    }
                                    picked = nil
                                    finger = nil
                                }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear { applyLayout(outer) }
                        .onChange(of: outer) { _, value in applyLayout(value) }
                }
            }
            // 点数の増え（右上）
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(game.gains) { gain in
                    Text(gain.text)
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(min(1, gain.life)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 86)
            .padding(.trailing, 22)
            .allowsHitTesting(false)
            if amassShown {
                Text("amass!")
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 0, x: 3, y: 3)
                    .shadow(color: .black, radius: 0, x: -3, y: -3)
                    .shadow(color: .black, radius: 0, x: 3, y: -3)
                    .shadow(color: .black, radius: 0, x: -3, y: 3)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
            if let popup = game.popup {
                VStack(spacing: 2) {
                    Text("achievement!")
                    Text(popup.text)
                }
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 30)
                .padding(.vertical, 16)
                .background(Capsule().fill(Color(white: 0.3)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(20)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .task(id: popup) {
                    try? await Task.sleep(for: .seconds(2.5))
                    game.popup = nil
                }
                .allowsHitTesting(false)
            }
            if game.gameOver { gameOverCard }
        }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: game.popup)
        .animation(.spring(duration: 0.35, bounce: 0.5), value: amassShown)
        .onChange(of: game.amass) { _, _ in
            amassShown = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                amassShown = false
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: game.gameOver)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .confirmationDialog("メニュー", isPresented: $showingMenu) {
            Button("最初からやり直す", role: .destructive) { game.restart() }
            Button("やめる") { dismiss() }
        }
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

    private func applyLayout(_ outer: CGFloat) {
        let inner = PuniBoard.innerRect(outer: outer)
        game.layout(width: Float(inner.width), height: Float(inner.height))
    }

    /// 上：メニュー（三本線）と、大きな灰色の点数
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                showingMenu = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(Color(white: 0.3))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("メニュー")
            Spacer()
            VStack(alignment: .trailing, spacing: -6) {
                Text("\(game.score)")
                    .font(.system(size: 64, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color(white: 0.27))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: game.score)
                Text("best \(game.best)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color(white: 0.3))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    private var gameOverCard: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("あふれた！")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                Text("\(game.score)")
                    .font(.system(size: 56, weight: .black, design: .rounded).monospacedDigit())
                Text(game.score >= game.best && game.score > 0 ? "ベスト更新！" : "best \(game.best)")
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.6))
                Button {
                    game.restart()
                } label: {
                    Text("もう一回")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(width: 200, height: 52)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                Button("やめる") { dismiss() }
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.6))
            }
            .foregroundStyle(.white)
            .padding(30)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(white: 0.2)))
            .padding(30)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }
}

/// 容器と玉を描く（毎コマ描き直す）。わくの外の大きさ outer に対して、中の黒いところの場所を決める
private struct PuniBoard: View {
    @ObservedObject var game: PuniGame
    let picked: Int?
    let finger: CGPoint?

    /// わくの太さ（横・下）と、上のわく（棒が 2 本入る）の太さ
    static func side(_ outer: CGFloat) -> CGFloat { outer * 0.04 }
    static func top(_ outer: CGFloat) -> CGFloat { outer * 0.065 }
    /// 外の高さ ÷ 外の幅
    static let heightRatio: CGFloat = 0.92 * 1.07 + 0.065 + 0.04

    static func innerRect(outer: CGFloat) -> CGRect {
        let w = outer - side(outer) * 2
        return CGRect(x: side(outer), y: top(outer), width: w, height: w * 1.07)
    }

    var body: some View {
        Canvas { context, size in
            _ = game.frame
            let outer = size.width
            let inner = Self.innerRect(outer: outer)
            drawFrame(&context, size: size, inner: inner)
            context.translateBy(x: inner.minX, y: inner.minY)
            drawQueue(&context)
            for blob in game.blobs { drawBlob(&context, blob) }
            drawAim(&context, inner: inner)
        }
    }

    private func point(_ v: PuniGame.Vec) -> CGPoint { CGPoint(x: CGFloat(v.x), y: CGFloat(v.y)) }

    /// 灰色のわく（下の角は斜め）、黒い中、左右の半円の出っぱり、上の 2 本の棒（危ないと白く伸びる）
    private func drawFrame(_ context: inout GraphicsContext, size: CGSize, inner: CGRect) {
        let s = Self.side(size.width)
        let c = CGFloat(game.chamfer)
        var outer = Path()
        let oc = c + s * 1.4
        outer.move(to: CGPoint(x: 14, y: 0))
        outer.addLine(to: CGPoint(x: size.width - 14, y: 0))
        outer.addQuadCurve(to: CGPoint(x: size.width, y: 14), control: CGPoint(x: size.width, y: 0))
        outer.addLine(to: CGPoint(x: size.width, y: size.height - oc))
        outer.addLine(to: CGPoint(x: size.width - oc, y: size.height))
        outer.addLine(to: CGPoint(x: oc, y: size.height))
        outer.addLine(to: CGPoint(x: 0, y: size.height - oc))
        outer.addLine(to: CGPoint(x: 0, y: 14))
        outer.addQuadCurve(to: CGPoint(x: 14, y: 0), control: .zero)
        outer.closeSubpath()
        context.fill(outer, with: .color(Color(white: 0.2)))
        var hole = Path()
        hole.move(to: CGPoint(x: inner.minX, y: inner.minY))
        hole.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
        hole.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY - c))
        hole.addLine(to: CGPoint(x: inner.maxX - c, y: inner.maxY))
        hole.addLine(to: CGPoint(x: inner.minX + c, y: inner.maxY))
        hole.addLine(to: CGPoint(x: inner.minX, y: inner.maxY - c))
        hole.closeSubpath()
        context.fill(hole, with: .color(.black))
        // 左右の半円の出っぱりと、わくのみぞ
        let by = inner.minY + CGFloat(game.bumperY), radius = CGFloat(game.bumperRadius)
        for x in [inner.minX, inner.maxX] {
            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: by - radius, width: radius * 2, height: radius * 2)),
                         with: .color(Color(white: 0.27)))
            context.fill(Path(ellipseIn: CGRect(x: x - radius * 0.8, y: by - radius * 0.8, width: radius * 1.6, height: radius * 1.6)),
                         with: .color(Color(white: 0.4)))
            context.fill(Path(roundedRect: CGRect(x: x - 2.5, y: by - radius * 1.6, width: 5, height: radius * 3.2), cornerRadius: 2.5),
                         with: .color(Color(white: 0.12)))
        }
        // 上の 2 本の棒：危なさに合わせて白い部分が伸びる
        let barY = inner.minY * 0.42, barH = max(4, inner.minY * 0.24)
        let danger = CGFloat(game.danger)
        for (start, end, fromRight) in [(size.width * 0.06, size.width * 0.42, false), (size.width * 0.58, size.width * 0.94, true)] {
            let track = CGRect(x: start, y: barY - barH / 2, width: end - start, height: barH)
            context.fill(Path(roundedRect: track, cornerRadius: barH / 2), with: .color(Color(white: 0.12)))
            let fill = max(0.12, danger) * track.width
            let lit = CGRect(x: fromRight ? track.maxX - fill : track.minX, y: track.minY, width: fill, height: barH)
            context.fill(Path(roundedRect: lit, cornerRadius: barH / 2),
                         with: .color(danger > 0.05 ? Color(white: 0.45 + 0.5 * danger) : Color(white: 0.4)))
        }
        // 上のふちの小さな点（列の玉の場所）
        for item in game.queueLayout() {
            let x = inner.minX + CGFloat(item.x)
            context.fill(Path(ellipseIn: CGRect(x: x - 3, y: inner.minY + 2, width: 6, height: 6)), with: .color(Color(white: 0.35)))
        }
    }

    /// 次の玉の列（細い筒につまって横につぶれた形）。ねらっている間は先頭を白くふちどる
    private func drawQueue(_ context: inout GraphicsContext) {
        let h = CGFloat(game.queueHeight)
        let y = CGFloat(game.queueY)
        for (index, item) in game.queueLayout().enumerated() {
            let rect = CGRect(x: CGFloat(item.x - item.width / 2), y: y - h / 2, width: CGFloat(item.width), height: h)
            let shape = Path(roundedRect: rect, cornerSize: CGSize(width: h * 0.42, height: h * 0.5))
            if index == picked {
                context.stroke(shape, with: .color(.white), lineWidth: 6)
            }
            context.fill(shape, with: .color(PuniGame.color(item.level)))
            label(&context, value: 1 << item.level, at: CGPoint(x: rect.midX, y: rect.midY), size: h * 0.5, dim: true, rotation: 0)
        }
    }

    private func drawBlob(_ context: inout GraphicsContext, _ blob: PuniGame.Blob) {
        let points = blob.pos.map(point)
        let count = points.count
        guard count > 2 else { return }
        // 点のあいだを少しなめらかにつなぐ
        var shape = Path()
        shape.move(to: CGPoint(x: (points[count - 1].x + points[0].x) / 2, y: (points[count - 1].y + points[0].y) / 2))
        for index in 0..<count {
            let current = points[index], following = points[(index + 1) % count]
            shape.addQuadCurve(to: CGPoint(x: (current.x + following.x) / 2, y: (current.y + following.y) / 2), control: current)
        }
        shape.closeSubpath()
        context.fill(shape, with: .color(PuniGame.color(blob.level)))
        if blob.flash > 0 {
            // くっついて生まれた直後は白く光る
            context.fill(shape, with: .color(.white.opacity(blob.flash * 0.85)))
        }
        context.stroke(shape, with: .color(.black), lineWidth: 2)
        let size = CGFloat(sqrt(max(blob.currentArea, 1))) * 0.34
        label(&context, value: blob.value, at: point(blob.center), size: size, dim: false, rotation: CGFloat(blob.rotation))
    }

    /// 玉の数字（黒。撃ったばかり・列のうしろの玉は色の濃い版にして目立たなくする）
    private func label(_ context: inout GraphicsContext, value: Int, at point: CGPoint, size: CGFloat, dim: Bool, rotation: CGFloat) {
        let digits = CGFloat(String(value).count)
        let fontSize = min(size, size * 2.6 / max(digits, 1))
        let text = Text("\(value)")
            .font(.system(size: max(fontSize, 8), weight: .black, design: .rounded))
            .foregroundStyle(dim ? Color.black.opacity(0.45) : Color.black)
        // 玉が転がると数字も一緒に回る
        var copy = context
        copy.translateBy(x: point.x, y: point.y)
        copy.rotate(by: .radians(rotation))
        copy.draw(text, at: .zero)
    }

    /// ねらい：選んだ玉から指まで白い線と矢印、指の場所に灰色の点
    private func drawAim(_ context: inout GraphicsContext, inner: CGRect) {
        guard let index = picked, let finger, !game.gameOver else { return }
        let origin = point(game.launchPoint(index))
        let dx = finger.x - origin.x, dy = finger.y - origin.y
        let length = hypot(dx, dy)
        context.fill(Path(ellipseIn: CGRect(x: finger.x - 11, y: finger.y - 11, width: 22, height: 22)), with: .color(Color(white: 0.5)))
        context.fill(Path(ellipseIn: CGRect(x: finger.x - 6, y: finger.y - 6, width: 12, height: 12)), with: .color(Color(white: 0.75)))
        guard length > 14 else { return }
        let end = CGPoint(x: origin.x + dx / length * (length - 14), y: origin.y + dy / length * (length - 14))
        var arrow = Path()
        arrow.move(to: origin)
        arrow.addLine(to: end)
        let angle = atan2(dy, dx)
        for side in [-1.0, 1.0] as [CGFloat] {
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(x: end.x - cos(angle + side * 0.45) * 20, y: end.y - sin(angle + side * 0.45) * 20))
        }
        context.stroke(arrow, with: .color(.white), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
    }
}
