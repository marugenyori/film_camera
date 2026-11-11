import SwiftUI
import CoreLocation

/// 撮影画面（共有アルバムの右下のボタンで全画面で開く。「アルバムに戻る」で閉じる）。teenage engineering の機材のような見た目：
/// アルミ色の筐体に画面を大きくはめ込み、上にランプつきの機能キー、下にスライドで選ぶモードと大きなシャッター、オレンジの差し色
struct ContentView: View {
    /// カメラはアプリ全体で 1 つ（閉じても最後に撮った写真や設定が残るよう、RootView が持つ）
    @ObservedObject var camera: CameraModel
    @ObservedObject private var album = AlbumStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var flashOpacity = 0.0
    @State private var showingPhoto = false
    @State private var showingContactSettings = false
    /// 隠しゲーム（倍率の黒い小窓を長押しすると開く）
    @State private var showingGame = false
    @AppStorage("showGrid") private var showGrid = false

    var body: some View {
        ZStack {
            Panel.body.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                ZStack(alignment: .bottom) {
                    preview
                    VStack(spacing: 10) {
                        if camera.mode == .double && camera.captureKind == .photo && !camera.isDual {
                            exposureOptions
                        }
                        if camera.mode == .contact && !camera.isDual {
                            Button {
                                showingContactSettings = true
                            } label: {
                                Label("\(camera.contactLayout.title)  フィルタと並べ方", systemImage: "square.grid.2x2")
                                    .panelChip()
                            }
                            .disabled(camera.isRecording)
                        }
                        if !camera.isDual {
                            // 2 倍まではワンタップで（iPhone のカメラと同じ丸いボタン）
                            ZoomQuickButtons(zoom: camera.zoom,
                                             presets: zoomPresets.filter { $0 <= 2 },
                                             onPreset: { camera.zoom(to: $0) })
                            ZoomRuler(zoom: camera.zoom,
                                      range: camera.zoomRange,
                                      presets: zoomPresets,
                                      onLever: { camera.zoomLever($0) },
                                      onPreset: { camera.zoom(to: $0) },
                                      onScrub: { camera.scrubZoom(to: $0) })
                        }
                    }
                    .padding(.bottom, 12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                controlPanel
            }

            // フラッシュで撮ったときに画面を白く光らせる
            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .onAppear {
            camera.start()
            LocationProvider.shared.start()
            applyRequestedMode()
        }
        .onDisappear {
            if camera.isRecording { camera.stopRecording() }
            camera.stop()
            LocationProvider.shared.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: camera.start()
            case .background:
                if camera.isRecording { camera.stopRecording() }
                camera.stop()
            default: break
            }
        }
        .onChange(of: camera.shotCount) { _, _ in
            guard camera.mode.usesDepth else { return }
            flashOpacity = 0.9
            withAnimation(.easeOut(duration: 0.4)) { flashOpacity = 0 }
        }
        .onChange(of: camera.message) { _, message in
            guard message != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(3))
                camera.message = nil
            }
        }
        .sensoryFeedback(.impact, trigger: camera.shotCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: camera.isRecording)
        .sensoryFeedback(.impact(weight: .light), trigger: camera.mode)
        // ズーム中は 0.1× ごとにカチカチと手応えを返す（ズームリングの目盛りのように）
        .sensoryFeedback(.selection, trigger: Int((camera.zoom * 10).rounded()))
        .sheet(isPresented: $showingContactSettings) {
            ContactSettingsView(camera: camera)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingPhoto) {
            if let photo = camera.lastPhoto {
                PhotoSheet(image: photo, addToAlbum: camera.lastPhotoFile.map { file -> () -> Void in
                    { album.add(data: file.data, type: file.type, thumbnail: photo, mode: file.mode,
                                location: LocationProvider.shared.recent) }
                })
            }
        }
        .onChange(of: album.requestedMode) { _, _ in applyRequestedMode() }
        .fullScreenCover(isPresented: $showingGame) {
            GameHubView(initialImage: camera.lastPhoto)
        }
        .onChange(of: showingGame) { _, playing in
            // 遊んでいる間はカメラを止めて電池を節約する
            if playing { camera.stop() } else { camera.start() }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: showingGame)
    }

    // MARK: - 上の段（機能キーと状態）

    private var topBar: some View {
        HStack(spacing: 8) {
            FunctionKey(systemImage: "calendar", isOn: camera.dateStamp, label: "日付") {
                camera.dateStamp.toggle()
            }
            FunctionKey(systemImage: camera.light ? "bolt.fill" : "bolt.slash", isOn: camera.light, label: "ライト") {
                camera.light.toggle()
            }
            .disabled(camera.isDual)
            FunctionKey(systemImage: "squareshape.split.3x3", isOn: showGrid, label: "グリッド") {
                showGrid.toggle()
            }
            if CameraModel.isDualSupported {
                FunctionKey(systemImage: "rectangle.inset.topleft.filled", isOn: camera.isDual,
                            label: "前後同時") {
                    camera.isDual.toggle()
                }
                .disabled(camera.isRecording || camera.isSaving)
            }
            Spacer(minLength: 6)
            statusReadout
                .font(.caption.weight(.semibold).monospaced())
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Panel.display, in: Capsule())
                // 隠しボタン：長押しでジュエル塗り絵
                .onLongPressGesture(minimumDuration: 1.0) { showingGame = true }
            Spacer(minLength: 6)
            FunctionKey(systemImage: "arrow.triangle.2.circlepath", isOn: nil, label: "カメラを切り替え") {
                camera.switchCamera()
            }
            .disabled(camera.status != .running || camera.isRecording || camera.isDual)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - プレビュー

    private var preview: some View {
        CameraPreview(model: camera)
            .overlay { ViewfinderFrame(showGrid: showGrid && camera.mode != .contact) }
            .overlay { statusOverlay }
            .overlay {
                if let diagnostic = camera.diagnostic {
                    Text(diagnostic)
                        .font(.caption.monospaced())
                        .foregroundStyle(Panel.ink)
                        .padding(12)
                        .background(Panel.key, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(20)
                        .textSelection(.enabled)
                }
            }
            .overlay(alignment: .top) {
                if let message = camera.message {
                    Text(message)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Panel.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Panel.key, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.top, 14)
                        .transition(.opacity)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { value in
                    guard !camera.isRecording else { return }
                    let dx = value.translation.width
                    guard abs(dx) > abs(value.translation.height) else { return }
                    shiftMode(by: dx < 0 ? 1 : -1)
                }
            )
            .onTapGesture(count: 2) {
                guard !camera.isRecording && !camera.isDual else { return }
                camera.switchCamera()
            }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .denied:
            VStack(spacing: 12) {
                Image(systemName: "camera.fill").font(.largeTitle)
                Text("カメラの使用が許可されていません")
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
        case .unavailable:
            VStack(spacing: 8) {
                Image(systemName: "camera.metering.unknown").font(.largeTitle)
                Text("カメラが見つかりません")
            }
            .foregroundStyle(.white.opacity(0.8))
        case .idle:
            ProgressView().tint(.white)
        case .running:
            EmptyView()
        }
    }

    private var zoomPresets: [CGFloat] {
        [0.5, 1, 2, 5].filter { camera.zoomRange.contains($0) || abs($0 - camera.zoomRange.lowerBound) < 0.02 }
    }

    // MARK: - 操作パネル

    /// 下の段：スライドで選ぶモードと、シャッター・最後の写真・写真／ビデオ
    /// アルバムの写真の「このフィルタで撮る」で選ばれたモードに切り替える
    private func applyRequestedMode() {
        guard let title = album.requestedMode else { return }
        if let mode = LookMode.allCases.first(where: { $0.title == title }) { camera.mode = mode }
        album.requestedMode = nil
    }

    private var controlPanel: some View {
        VStack(spacing: 6) {
            ModeSlider(selection: $camera.mode)
                .disabled(camera.isRecording)
                .opacity(camera.isRecording ? 0.4 : 1)
            HStack {
                HStack(spacing: 8) {
                    thumbnail
                    FunctionKey(systemImage: "person.2.fill", isOn: album.autoAdd, label: "アルバムに戻る") {
                        dismiss()
                    }
                }
                .frame(width: 96, alignment: .leading)
                Spacer()
                ShutterButton(kind: camera.captureKind,
                              isRecording: camera.isRecording,
                              isBusy: camera.isSaving) {
                    camera.shutterPressed()
                }
                .disabled(camera.status != .running || (camera.isSaving && !camera.isRecording))
                Spacer()
                KindSwitch(kind: camera.captureKind, videoAllowed: !camera.isDual) { kind in
                    withAnimation(.snappy(duration: 0.25)) { camera.captureKind = kind }
                }
                .disabled(camera.isRecording || camera.isSaving)
                .frame(width: 96, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var statusReadout: some View {
        if camera.isRecording, let start = camera.recordingStartedAt {
            TimelineView(.periodic(from: start, by: 0.5)) { context in
                let seconds = Int(context.date.timeIntervalSince(start))
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text(String(format: "REC %02d:%02d", seconds / 60, seconds % 60))
                        .foregroundStyle(.white)
                }
            }
        } else if camera.mode == .double && !camera.exposures.isEmpty && !camera.isBursting {
            Button {
                camera.discardExposures()
            } label: {
                HStack(spacing: 5) {
                    Text("\(camera.exposures.count)/\(camera.exposureCount)")
                    Image(systemName: "arrow.uturn.backward")
                }
                .foregroundStyle(.tint)
            }
            .accessibilityLabel("撮り直す")
        } else {
            HStack(spacing: 8) {
                if camera.mode.usesDepth && camera.isDepthActive && !camera.isDual {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint)
                        .accessibilityLabel("距離で光を調整")
                }
                if camera.isDual {
                    Image(systemName: "rectangle.inset.topleft.filled").foregroundStyle(.tint)
                        .accessibilityLabel("前後同時")
                } else {
                    Text(ZoomRuler.label(camera.zoom) + "×").foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    private var thumbnail: some View {
        Button {
            showingPhoto = true
        } label: {
            Group {
                if let photo = camera.lastPhoto {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    Panel.display
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Panel.ink.opacity(0.25), lineWidth: 1))
        }
        .disabled(camera.lastPhoto == nil || camera.isRecording)
        .accessibilityLabel("最後に撮った写真")
    }

    // MARK: - 多重露光の設定

    private var exposureOptions: some View {
        HStack(spacing: 4) {
            ForEach(2...4, id: \.self) { count in
                let selected = camera.exposureCount == count
                Button {
                    camera.exposureCount = count
                } label: {
                    Text("\(count)枚")
                        .font(.caption2.weight(.bold).monospaced())
                        .foregroundStyle(selected ? Color.white : Panel.ink)
                        .frame(width: 46, height: 28)
                        .background(Capsule().fill(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.clear)))
                }
                .buttonStyle(.plain)
            }
            Rectangle().fill(Panel.ink.opacity(0.2)).frame(width: 1, height: 18).padding(.horizontal, 4)
            Menu {
                Picker("撮り方", selection: $camera.burstInterval) {
                    ForEach(CameraModel.burstIntervals, id: \.self) { interval in
                        Text(Self.burstLabel(interval)).tag(interval)
                    }
                }
            } label: {
                Label(Self.burstLabel(camera.burstInterval), systemImage: "timer")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Panel.ink)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
            }
        }
        .padding(4)
        .background(Capsule().fill(Panel.key))
        .disabled(camera.isBursting || !camera.exposures.isEmpty)
    }

    private static func burstLabel(_ interval: Double) -> String {
        if interval == 0 { return "手動" }
        let seconds = interval < 1 ? String(format: "%.1f", interval) : String(format: "%.0f", interval)
        return interval < CameraModel.fastBurstLimit
            ? "\(seconds)秒ごと（1200万画素）"
            : "\(seconds)秒ごと"
    }

    private func shiftMode(by step: Int) {
        let all = LookMode.allCases
        guard let index = all.firstIndex(of: camera.mode) else { return }
        let next = index + step
        guard all.indices.contains(next) else { return }
        withAnimation(.snappy) { camera.mode = all[next] }
    }
}

// MARK: - 筐体の色

/// 操作パネルの色（筐体はアルミのような明るい灰色。オレンジはテーマ色 `.tint`）
private enum Panel {
    static let body = Color(hex: 0xDDDCD7)
    static let key = Color(hex: 0xF5F4F0)
    static let ink = Color(hex: 0x1C1C1C)
    /// 筐体に印刷された小さな文字
    static let print = Color(hex: 0x76756F)
    static let display = Color(hex: 0x121212)
}

/// 四角いキー。押すと沈み、選ばれているとオレンジに光る
private struct PanelKeyStyle: ButtonStyle {
    var lit = false

    func makeBody(configuration: Configuration) -> some View {
        PanelKey(configuration: configuration, lit: lit)
    }

    private struct PanelKey: View {
        let configuration: ButtonStyleConfiguration
        let lit: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .foregroundStyle(lit ? Color.white : Panel.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(lit ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Panel.key))
                        .shadow(color: .black.opacity(pressed ? 0 : 0.22), radius: 0, x: 0, y: pressed ? 0 : 2)
                )
                .offset(y: pressed ? 2 : 0)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.snappy(duration: 0.08), value: pressed)
        }
    }
}

/// モードを選ぶスライド。名前を横に並べ、なぞって見渡し、押して選ぶ（プレビューを左右になぞっても切り替わる）。
/// 選んだモードは自動で真ん中に来る。スクロール位置から選択を決める方式は、
/// 選択とスクロールが互いに書き換え合って画面が止まるおそれがあるので使わない
private struct ModeSlider: View {
    @Binding var selection: LookMode
    private let itemWidth: CGFloat = 96

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(LookMode.allCases) { mode in
                            let selected = mode == selection
                            Button {
                                withAnimation(.snappy) { selection = mode }
                            } label: {
                                VStack(spacing: 4) {
                                    Text(mode.title)
                                        .font(.subheadline.weight(selected ? .bold : .medium))
                                        .foregroundStyle(selected ? Panel.ink : Panel.print.opacity(0.7))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    Circle()
                                        .fill(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.clear))
                                        .frame(width: 5, height: 5)
                                }
                                .frame(width: itemWidth, height: 40)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(mode)
                        }
                    }
                    .padding(.horizontal, max(0, (geo.size.width - itemWidth) / 2))
                }
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 0.18),
                                           .init(color: .black, location: 0.82),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .onChange(of: selection) { _, mode in
                    withAnimation(.snappy) { proxy.scrollTo(mode, anchor: .center) }
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .center) }
                }
            }
        }
        .frame(height: 40)
    }
}

/// 機能キー：アイコンだけのキーに小さなランプ（isOn が nil ならランプなし）
private struct FunctionKey: View {
    let systemImage: String
    let isOn: Bool?
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let isOn {
                        Circle()
                            .fill(isOn ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Panel.print.opacity(0.3)))
                            .frame(width: 5, height: 5)
                            .padding(5)
                    }
                }
            }
            .buttonStyle(PanelKeyStyle())
            .frame(width: 44, height: 34)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.map { $0 ? "オン" : "オフ" } ?? "")
    }
}

/// 写真／ビデオのスライドスイッチ
private struct KindSwitch: View {
    let kind: CameraModel.CaptureKind
    let videoAllowed: Bool
    let onChange: (CameraModel.CaptureKind) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment("camera.fill", .photo)
            segment("video.fill", .video)
                .disabled(!videoAllowed)
                .opacity(videoAllowed ? 1 : 0.35)
        }
        .padding(3)
        .background(Capsule().fill(Panel.display))
    }

    private func segment(_ systemImage: String, _ value: CameraModel.CaptureKind) -> some View {
        let selected = kind == value
        return Button {
            onChange(value)
        } label: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.45))
                .frame(width: 46, height: 38)
                .background {
                    if selected {
                        Capsule().fill(value == .video ? AnyShapeStyle(Color.red) : AnyShapeStyle(TintShapeStyle()))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == .photo ? "写真" : "ビデオ")
    }
}

/// シャッター。黒い縁の大きな丸いキー（ビデオは赤、録画中は中に白い四角）
private struct ShutterButton: View {
    let kind: CameraModel.CaptureKind
    let isRecording: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(ShutterStyle(kind: kind, isRecording: isRecording, isBusy: isBusy))
        .accessibilityLabel(kind == .video ? (isRecording ? "録画を止める" : "録画する") : "シャッター")
    }

    private struct ShutterStyle: ButtonStyle {
        let kind: CameraModel.CaptureKind
        let isRecording: Bool
        let isBusy: Bool

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            ZStack {
                Circle()
                    .fill(Panel.ink)
                    .frame(width: 92, height: 92)
                Circle()
                    .fill(kind == .video ? AnyShapeStyle(Color.red) : AnyShapeStyle(Panel.key))
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(pressed ? 0 : 0.35), radius: 0, x: 0, y: pressed ? 0 : 3)
                    .offset(y: pressed ? 3 : 0)
                Group {
                    if isRecording {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.white)
                            .frame(width: 24, height: 24)
                    } else if isBusy {
                        ProgressView().tint(kind == .video ? .white : Panel.ink)
                    } else if kind == .photo {
                        Circle()
                            .fill(.tint)
                            .frame(width: 10, height: 10)
                    }
                }
                .offset(y: pressed ? 3 : 0)
            }
            .animation(.snappy(duration: 0.1), value: pressed)
            .animation(.snappy(duration: 0.25), value: isRecording)
            .animation(.snappy(duration: 0.25), value: kind)
        }
    }
}

private extension View {
    /// ズームのレバーなどに使う、小さな等幅の文字
    func hudText() -> some View {
        self
            .font(.caption2.weight(.semibold).monospaced())
            .tracking(1.2)
            .lineLimit(1)
    }

    /// プレビューの上に置く、白いキーのような札
    func panelChip() -> some View {
        self
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(Panel.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Panel.key))
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - 部品

/// ファインダーの枠：写真の範囲（縦 4:3）の四隅に細いかぎ括弧、必要なら三分割の線
private struct ViewfinderFrame: View {
    let showGrid: Bool

    var body: some View {
        GeometryReader { geo in
            let aspect: CGFloat = 3.0 / 4.0
            let width = min(geo.size.width, geo.size.height * aspect)
            let height = width / aspect
            let rect = CGRect(x: (geo.size.width - width) / 2, y: (geo.size.height - height) / 2,
                              width: width, height: height).insetBy(dx: 12, dy: 12)
            let arm: CGFloat = 16
            ZStack {
                Path { path in
                    let corners: [(CGPoint, CGFloat, CGFloat)] = [
                        (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
                        (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
                        (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
                        (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
                    ]
                    for (corner, dx, dy) in corners {
                        path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
                        path.addLine(to: corner)
                        path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
                    }
                }
                .stroke(Color.white.opacity(0.7), lineWidth: 1)

                if showGrid {
                    Path { path in
                        for i in 1...2 {
                            let x = rect.minX + rect.width * CGFloat(i) / 3
                            path.move(to: CGPoint(x: x, y: rect.minY))
                            path.addLine(to: CGPoint(x: x, y: rect.maxY))
                            let y = rect.minY + rect.height * CGFloat(i) / 3
                            path.move(to: CGPoint(x: rect.minX, y: y))
                            path.addLine(to: CGPoint(x: rect.maxX, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// ズームの目盛り。レンズのリングのように、倍率に合わせて目盛りが流れる。
/// なぞると倍率が追いかけ、数字を押すとその倍率まで一定の速さで動き、W / T は押している間だけ動く
private struct ZoomRuler: View {
    let zoom: CGFloat
    let range: ClosedRange<CGFloat>
    let presets: [CGFloat]
    let onLever: (Int) -> Void
    let onPreset: (CGFloat) -> Void
    let onScrub: (CGFloat) -> Void

    @State private var dragStartZoom: CGFloat?
    /// 倍率が 2 倍になるごとの目盛りの間隔
    private let pointsPerStop: CGFloat = 60

    var body: some View {
        HStack(spacing: 2) {
            ZoomLever(title: "W") { onLever($0 ? -1 : 0) }
            GeometryReader { geo in
                let mid = geo.size.width / 2
                let current = log2(max(zoom, 0.01))
                ZStack {
                    Canvas { context, size in
                        let low = Int((log2(range.lowerBound) * 10).rounded(.up))
                        let high = Int((log2(range.upperBound) * 10).rounded(.down))
                        guard low <= high else { return }
                        for step in low...high {
                            let x = mid + (CGFloat(step) / 10 - current) * pointsPerStop
                            guard x >= 0, x <= size.width else { continue }
                            let major = step % 10 == 0
                            var tick = Path()
                            tick.move(to: CGPoint(x: x, y: 18))
                            tick.addLine(to: CGPoint(x: x, y: major ? 30 : 25))
                            context.stroke(tick, with: .color(.white.opacity(major ? 0.85 : 0.35)), lineWidth: 1)
                        }
                    }
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            onPreset(preset)
                        } label: {
                            Text(Self.label(preset))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 30, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .position(x: mid + (log2(preset) - current) * pointsPerStop, y: 42)
                    }
                    Text(Self.label(zoom) + "×")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.tint)
                        .position(x: mid, y: 7)
                    Rectangle()
                        .fill(.tint)
                        .frame(width: 1.5, height: 18)
                        .position(x: mid, y: 24)
                }
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 0.2),
                                           .init(color: .black, location: 0.8),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let start = dragStartZoom ?? zoom
                            if dragStartZoom == nil { dragStartZoom = zoom }
                            let target = start * pow(2, -value.translation.width / pointsPerStop)
                            onScrub(min(max(target, range.lowerBound), range.upperBound))
                        }
                        .onEnded { _ in dragStartZoom = nil }
                )
            }
            .frame(width: 190, height: 52)
            ZoomLever(title: "T") { onLever($0 ? 1 : 0) }
        }
        .padding(.horizontal, 6)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ズーム \(Self.label(zoom))倍")
    }

    static func label(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() && rounded >= 1
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }
}

/// 0.5・1・2 倍に、ワンタップで切り替える丸いボタン。いまの倍率にいちばん近いボタンを光らせ、その倍率を出す
private struct ZoomQuickButtons: View {
    let zoom: CGFloat
    let presets: [CGFloat]
    let onPreset: (CGFloat) -> Void

    var body: some View {
        let nearest = presets.min { abs(log2($0) - log2(zoom)) < abs(log2($1) - log2(zoom)) }
        HStack(spacing: 10) {
            ForEach(presets, id: \.self) { preset in
                let selected = preset == nearest
                Button {
                    onPreset(preset)
                } label: {
                    Text(selected ? ZoomRuler.label(zoom) + "×" : ZoomRuler.label(preset))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.85)))
                        .frame(width: selected ? 44 : 36, height: selected ? 44 : 36)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(ZoomRuler.label(preset))倍")
            }
        }
        .padding(6)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .animation(.snappy(duration: 0.2), value: nearest)
    }
}

/// 押している間だけ動くズームレバー（離すと止まる）
private struct ZoomLever: View {
    let title: String
    let onPress: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        Text(title)
            .hudText()
            .foregroundStyle(pressed ? Color.black : Color.white.opacity(0.85))
            .frame(width: 34, height: 34)
            .background(Circle().fill(pressed ? Color.white : Color.clear))
            .overlay(Circle().stroke(.white.opacity(pressed ? 0 : 0.25), lineWidth: 0.5))
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.15), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        onPress(true)
                    }
                    .onEnded { _ in
                        pressed = false
                        onPress(false)
                    }
            )
            .accessibilityLabel(title == "W" ? "広角へズーム" : "望遠へズーム")
    }
}

/// 最後に撮った写真を大きく表示する
private struct PhotoSheet: View {
    let image: UIImage
    /// 共有アルバムに追加する（保存したファイルがあるときだけ）
    let addToAlbum: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var added = false

    var body: some View {
        NavigationStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: Image(uiImage: image),
                                  preview: SharePreview("写真", image: Image(uiImage: image)))
                    }
                    if let addToAlbum {
                        ToolbarItem(placement: .bottomBar) {
                            Button {
                                addToAlbum()
                                added = true
                            } label: {
                                Label(added ? "共有アルバムに追加しました" : "共有アルバムに追加",
                                      systemImage: added ? "checkmark.circle.fill" : "person.2.fill")
                            }
                            .disabled(added)
                        }
                    }
                }
                .navigationTitle("写真アプリに保存しました")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 分割の設定：並べ方と、コマごとのフィルタを選ぶ
private struct ContactSettingsView: View {
    @ObservedObject var camera: CameraModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("並べ方（横×縦）") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 14) {
                        ForEach(ContactLayout.allCases) { layout in
                            Button {
                                camera.contactLayout = layout
                            } label: {
                                VStack(spacing: 6) {
                                    LayoutIcon(layout: layout, selected: camera.contactLayout == layout)
                                        .frame(width: 40, height: 40)
                                    Text(layout.title)
                                        .font(.caption2.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(camera.contactLayout == layout
                                                         ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.secondary))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    ForEach(0..<camera.contactLayout.count, id: \.self) { index in
                        Picker(selection: slotBinding(index)) {
                            ForEach(ContactLayout.selectableModes) { mode in
                                Text(mode.title).tag(mode)
                            }
                        } label: {
                            Text(slotName(index))
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("コマごとのフィルタ")
                } footer: {
                    Text("左上から右へ、上の段から順に並びます。同じフィルタを何回使ってもかまいません。")
                }

                Section {
                    Toggle("各コマにフィルタ名を入れる", isOn: $camera.contactLabels)
                }
            }
            .navigationTitle("分割の設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    private func slotBinding(_ index: Int) -> Binding<LookMode> {
        Binding(
            get: { camera.contactSlots[index] },
            set: { camera.contactSlots[index] = $0 }
        )
    }

    /// 「1段目・左」のような、コマの場所の名前
    private func slotName(_ index: Int) -> String {
        let layout = camera.contactLayout
        let row = index / layout.columns + 1
        let column = index % layout.columns + 1
        return layout.columns == 1 ? "\(row)段目" : "\(row)段目・\(column)列目"
    }
}

/// 並べ方の小さな絵
private struct LayoutIcon: View {
    let layout: ContactLayout
    let selected: Bool

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let cellW = (geo.size.width - gap * CGFloat(layout.columns - 1)) / CGFloat(layout.columns)
            let cellH = (geo.size.height - gap * CGFloat(layout.rows - 1)) / CGFloat(layout.rows)
            VStack(spacing: gap) {
                ForEach(0..<layout.rows, id: \.self) { _ in
                    HStack(spacing: gap) {
                        ForEach(0..<layout.columns, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.secondary.opacity(0.5)))
                                .frame(width: cellW, height: cellH)
                        }
                    }
                }
            }
        }
    }
}
