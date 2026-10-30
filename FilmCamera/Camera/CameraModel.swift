import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit

/// カメラの制御。映像の各フレームは `latestFrame` に置き、
/// 画面側（CameraPreview）がそれを取り出してフィルタをかけて表示する。
///
/// フラッシュモードのときだけ、LiDAR（なければデュアルカメラ）で距離を測り、
/// `latestDepth` に置く。距離が近いものほど強く光が当たったように見せるのに使う。
final class CameraModel: NSObject, ObservableObject {

    enum Status {
        case idle
        case running
        case denied
        case unavailable
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var position: AVCaptureDevice.Position = .back
    /// 最後に撮った写真（左下の小窓）。アプリを閉じても残るよう、小さく保存しておく
    @Published private(set) var lastPhoto: UIImage? {
        didSet {
            let url = Self.lastPhotoURL
            let data = lastPhoto?.jpegData(compressionQuality: 0.8)
            DispatchQueue.global(qos: .utility).async {
                if let data { try? data.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
            }
        }
    }
    private static var lastPhotoURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lastPhoto.jpg")
    }
    /// 最後に保存した写真のファイル（共有アルバムに送るため）
    private(set) var lastPhotoFile: (data: Data, type: String, mode: String)?
    @Published private(set) var isSaving = false
    @Published private(set) var shotCount = 0
    /// 距離の測定が動いているか（フラッシュモードで LiDAR などが使えるとき）
    @Published private(set) var isDepthActive = false
    @Published var message: String?
    /// カメラの映像が届かないときの原因調べ用の表示（映像が届けば消える）
    @Published private(set) var diagnostic: String?

    @Published var mode: LookMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            if mode.usesDepth != oldValue.usesDepth || mode.usesRaw != oldValue.usesRaw {
                let raw = mode.usesRaw
                sessionQueue.async { self.wantsRawCamera = raw }
                updateDepth()
            }
            if mode != .double { discardExposures() }
        }
    }

    // MARK: 多重露光

    /// 何枚重ねるか（2〜4）
    @Published var exposureCount: Int {
        didSet {
            UserDefaults.standard.set(exposureCount, forKey: "exposureCount")
            discardExposures()
        }
    }
    /// 連続で撮る間隔（秒）。0 は 1 枚ずつ手動でシャッターを切る
    @Published var burstInterval: Double {
        didSet { UserDefaults.standard.set(burstInterval, forKey: "burstInterval") }
    }
    static let burstIntervals: [Double] = [0, 0.1, 0.3, 0.5, 1, 2]
    /// この間隔より短い連射は、4800万画素では間に合わないので 1200万画素・速さ優先で撮る
    static let fastBurstLimit: Double = 0.5

    /// 撮り終えた分（保存用のフル解像度。向きは適用済み）
    @Published private(set) var exposures: [CIImage] = []
    /// 撮り終えた分を、プレビューに重ねる用に小さくしたもの
    @Published private(set) var exposurePreviews: [CIImage] = []
    /// 連射中か（途中でシャッターや撮り直しを受け付けない）
    @Published private(set) var isBursting = false

    /// 撮り終えた分を捨てて、最初から撮り直せるようにする
    func discardExposures() {
        guard !isBursting else { return }
        exposures = []
        exposurePreviews = []
    }
    @Published var dateStamp: Bool {
        didSet { UserDefaults.standard.set(dateStamp, forKey: "dateStamp") }
    }

    // MARK: 写真と動画

    enum CaptureKind: String {
        case photo
        case video
    }

    @Published var captureKind: CaptureKind {
        didSet {
            UserDefaults.standard.set(captureKind.rawValue, forKey: "captureKind")
            updateTorch()
        }
    }
    /// iPhone の本物のライト。写真は撮る瞬間にフラッシュを光らせ、ビデオでは点けっぱなしにする
    @Published var light: Bool {
        didSet {
            UserDefaults.standard.set(light, forKey: "light")
            updateTorch()
        }
    }
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?

    // MARK: 分割

    @Published var contactLayout: ContactLayout {
        didSet { UserDefaults.standard.set(contactLayout.rawValue, forKey: "contactLayout") }
    }
    /// コマごとのフィルタ（いちばん多い並べ方の分まで持っておく）
    @Published var contactSlots: [LookMode] {
        didSet { UserDefaults.standard.set(contactSlots.map(\.rawValue), forKey: "contactSlots") }
    }
    @Published var contactLabels: Bool {
        didSet { UserDefaults.standard.set(contactLabels, forKey: "contactLabels") }
    }
    static let maxContactSlots = ContactLayout.allCases.map(\.count).max() ?? 9

    /// 今の設定でフィルタをかけるときの設定（距離や重ねる画像は呼ぶ側で足す）
    var baseOptions: LookOptions {
        var options = LookOptions(mode: mode, dateStamp: dateStamp)
        options.contactLayout = contactLayout
        options.contactModes = Array(contactSlots.prefix(contactLayout.count))
        options.contactLabels = contactLabels
        return options
    }

    // MARK: 前後同時撮影

    /// 外カメラと内カメラを同時に使うか（オンの間はふだんのセッションを止め、マルチカメラに切り替える）
    @Published var isDual = false {
        didSet {
            guard isDual != oldValue else { return }
            if isDual { captureKind = .photo }
            switchDual(isDual)
        }
    }
    static var isDualSupported: Bool { DualCameraSession.isSupported }
    private let dual = DualCameraSession()

    // MARK: ズーム

    /// 画面に出す倍率（0.5×・1×・2× …）。広角カメラの 1 倍を 1× とする
    @Published private(set) var zoom: CGFloat = 1
    /// 使える倍率の範囲（表示上の倍率）
    @Published private(set) var zoomRange: ClosedRange<CGFloat> = 1...1
    /// 表示上の倍率 = カメラの倍率 × これ（超広角から始まるカメラでは 0.5）。メインスレッドで使う
    private var zoomMultiplier: CGFloat = 1
    private weak var zoomDevice: AVCaptureDevice?
    private var zoomTimer: Timer?
    /// ズームの上限（2× を超える分はセンサーの切り出しではなく拡大になるので、控えめにする）
    static let maxDisplayZoom: CGFloat = 5

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video")
    private let processingQueue = DispatchQueue(label: "camera.processing", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    /// マイクをセッションに追加済みか（sessionQueue で触る）
    private var hasAudio = false
    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false
    /// 距離の出力をセッションに追加できたか（sessionQueue で触る）
    private var hasDepthOutput = false
    /// 今、距離を測る設定になっているか（sessionQueue で触る）
    private var isDepthOn = false

    /// 端末の傾きから、保存する写真の向きを決める（メインスレッドで使う）
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    /// 撮影中の写真の受け取り役（撮影が終わるまで保持する。sessionQueue で触る）
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]

    private let frameLock = NSLock()
    private var _latestFrame: CIImage?
    /// 届いた映像のコマ数（映像が止まっていないかを見張る）
    private var _frameCount = 0
    /// 自分で選んだ設定で映像が届かなかったので、標準の設定（.photo）に任せているか
    private var useStandardFormat = false
    /// セッションで起きた最後のエラー（原因調べ用）
    private var lastRuntimeError: String?
    private var lastInterruption: String?
    /// デュアルカメラで映像が届かなかったので、広角カメラだけを使っているか
    private var useSimpleCamera = false
    /// RAW で撮るモード中か（sessionQueue で使う）。RAW はレンズを自動で切り替えるカメラでは撮れないので、
    /// 広角カメラだけを使う
    private var wantsRawCamera = false
    /// RAW で撮れないことを知らせたか
    private var toldRawUnavailable = false
    private var _latestFrontFrame: CIImage?
    /// 前後同時撮影を始めてから届いたコマの数（映像が来ているかの確認用）
    private var _dualFrameCount = 0
    private var _latestDepth: CIImage?
    private var _subjectDistance: CGFloat?
    /// 距離の画像を接続側で縦向きにできたか（できなければ自分で回す）
    private var _depthRotatedByConnection = false
    /// 設定が変わってもズームを保つための、表示上の倍率
    private var _desiredZoom: CGFloat = 1
    /// 録画を続けたいか（開始の準備中に停止されたときのため）
    private var _wantsRecording = false

    // 録画中の状態（recordingQueue で触る）。
    // フィルタをかけて書き込む処理は重いので、カメラの映像を受け取るキューとは分ける。
    // 前のコマを書き込み中なら次のコマは飛ばし、処理待ちが積み上がらないようにする
    private let recordingQueue = DispatchQueue(label: "camera.recording", qos: .userInitiated)
    private var _recordingActive = false   // frameLock で守る
    private var _renderingFrame = false    // frameLock で守る
    private var recorder: VideoRecorder?
    private var recordingOptions: LookOptions?
    private var recordingTransform: CGAffineTransform = .identity
    private var recordingWithAudio = false
    private var lastRecordedFrame: CIImage?
    private let videoContext = CIContext(options: [.cacheIntermediates: false])

    /// 最新の映像フレーム（縦向き・インカメラは左右反転済み）
    var latestFrame: CIImage? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _latestFrame
    }

    /// 前後同時撮影の、内カメラの最新のコマ（縦向き・左右反転済み）
    var latestFrontFrame: CIImage? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _latestFrontFrame
    }

    /// 最新の距離（メートル）。映像と同じ縦向き。距離を測っていないときは nil
    var latestDepth: CIImage? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _latestDepth
    }

    /// 画面中央にあるもの（主な被写体）までの距離（メートル）。フラッシュの強さをこの距離に合わせる
    var subjectDistance: CGFloat? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _subjectDistance
    }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    override init() {
        let defaults = UserDefaults.standard
        mode = LookMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .film
        dateStamp = defaults.bool(forKey: "dateStamp")
        light = defaults.bool(forKey: "light")
        let count = defaults.integer(forKey: "exposureCount")
        exposureCount = (2...4).contains(count) ? count : 2
        burstInterval = defaults.double(forKey: "burstInterval")
        captureKind = CaptureKind(rawValue: defaults.string(forKey: "captureKind") ?? "") ?? .photo
        contactLayout = ContactLayout(rawValue: defaults.string(forKey: "contactLayout") ?? "") ?? .c2x3
        var slots = (defaults.stringArray(forKey: "contactSlots") ?? []).compactMap(LookMode.init(rawValue:))
        let fallback = ContactLayout.defaultModes + ContactLayout.defaultModes
        while slots.count < (ContactLayout.allCases.map(\.count).max() ?? 9) {
            slots.append(fallback[slots.count % fallback.count])
        }
        contactSlots = slots
        contactLabels = defaults.object(forKey: "contactLabels") as? Bool ?? true
        super.init()
        try? FileManager.default.createDirectory(at: Self.lastPhotoURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        lastPhoto = UIImage(contentsOfFile: Self.lastPhotoURL.path)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted,
                                               object: session)
        dual.onFrame = { [weak self] frame, isBack in
            guard let self else { return }
            self.frameLock.lock()
            if isBack { self._latestFrame = frame } else { self._latestFrontFrame = frame }
            self._dualFrameCount += 1
            self.frameLock.unlock()
        }
    }

    // MARK: - 起動と停止

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.startSession()
                    } else {
                        self.status = .denied
                    }
                }
            }
        default:
            status = .denied
        }
        updateTorch()
    }

    /// ビデオでライトがオンなら点け、それ以外は消す（前後同時のときは使わない）
    private func updateTorch() {
        let on = light && captureKind == .video && !isDual
        sessionQueue.async {
            guard let device = self.videoInput?.device, device.hasTorch,
                  device.isTorchModeSupported(on ? .on : .off),
                  (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.dual.stop()
        }
    }

    /// ふだんのセッションとマルチカメラを切り替える
    private func switchDual(_ on: Bool) {
        guard isConfigured else { return }
        let position = self.position
        let wantDepth = mode.usesDepth
        sessionQueue.async {
            if on {
                // カメラは同時に 1 つのセッションにしかつなげないので、ふだんのセッションから外してから渡す
                if self.session.isRunning { self.session.stopRunning() }
                self.session.beginConfiguration()
                if let input = self.videoInput { self.session.removeInput(input) }
                self.videoInput = nil
                self.session.commitConfiguration()
                self.frameLock.lock()
                self._dualFrameCount = 0
                self.frameLock.unlock()

                guard self.dual.start() else {
                    DispatchQueue.main.async {
                        self.message = "この機種では前後同時撮影が使えません"
                        self.isDual = false
                    }
                    return
                }
                // 2 秒たっても映像が届かなければ、あきらめてふだんの撮影に戻す
                self.sessionQueue.asyncAfter(deadline: .now() + 2) {
                    self.frameLock.lock()
                    let frames = self._dualFrameCount
                    self.frameLock.unlock()
                    guard frames == 0 else { return }
                    DispatchQueue.main.async {
                        guard self.isDual else { return }
                        self.message = "前後同時撮影を始められませんでした"
                        self.isDual = false
                    }
                }
            } else {
                self.dual.stop()
                self.frameLock.lock()
                self._latestFrontFrame = nil
                self.frameLock.unlock()
                // ふだんのセッションにカメラをつなぎ直す
                self.session.beginConfiguration()
                if let device = self.useCamera(at: position, wantDepth: wantDepth) {
                    self.applyFormat(for: device, wantDepth: wantDepth)
                    self.setUpConnections(for: device)
                }
                self.session.commitConfiguration()
                self.refreshPhotoDepthDelivery()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    private func startSession() {
        let position = self.position
        let wantDepth = mode.usesDepth
        let wantRaw = mode.usesRaw
        let dualOn = isDual
        sessionQueue.async {
            self.wantsRawCamera = wantRaw
            if !self.isConfigured {
                self.isConfigured = self.configure(position: position, wantDepth: wantDepth)
            }
            guard self.isConfigured else {
                DispatchQueue.main.async { self.status = .unavailable }
                return
            }
            self.refreshPhotoDepthDelivery()
            if dualOn {
                _ = self.dual.start()
            } else if !self.session.isRunning {
                self.session.startRunning()
            }
            if !dualOn { self.watchForFrames() }
            DispatchQueue.main.async {
                self.status = .running
                self.startZoomTracking()
            }
        }
    }

    /// 映像が届いているかを見張る（sessionQueue で呼ぶ）。
    /// iPhone 13（iOS 26）で、セッションが動かず映像が 1 コマも届かないことがあった。
    /// 届かなければ段階的にやり直す：①標準の設定（.photo）に任せる ②デュアルカメラをやめて
    /// 広角カメラだけ・距離なしで組み直す。それでもだめなら原因調べ用の情報を出す
    private func watchForFrames(stage: Int = 0) {
        frameLock.lock()
        let before = _frameCount
        frameLock.unlock()
        sessionQueue.asyncAfter(deadline: .now() + 2.5) {
            self.frameLock.lock()
            let after = self._frameCount
            self.frameLock.unlock()
            if after > before || self.isDual {
                DispatchQueue.main.async { self.diagnostic = nil }
                return
            }
            switch stage {
            case 0:
                self.useStandardFormat = true
                self.session.beginConfiguration()
                self.removeDepthOutput()
                self.session.sessionPreset = .photo
                if let device = self.videoInput?.device { self.setUpConnections(for: device) }
                self.session.commitConfiguration()
            case 1:
                self.useSimpleCamera = true
                self.session.stopRunning()
                self.session.beginConfiguration()
                self.removeDepthOutput()
                let position = self.videoInput?.device.position ?? .back
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                   let input = try? AVCaptureDeviceInput(device: device) {
                    if let current = self.videoInput { self.session.removeInput(current) }
                    self.session.sessionPreset = .photo
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.videoInput = input
                    }
                    self.setUpConnections(for: device)
                }
                self.session.commitConfiguration()
            default:
                self.showDiagnostic()
                return
            }
            self.refreshPhotoDepthDelivery()
            if !self.session.isRunning { self.session.startRunning() }
            self.watchForFrames(stage: stage + 1)
        }
    }

    /// 距離の出力を外す（sessionQueue の beginConfiguration〜commitConfiguration の中で呼ぶ）
    private func removeDepthOutput() {
        guard hasDepthOutput else { return }
        session.removeOutput(depthOutput)
        hasDepthOutput = false
        isDepthOn = false
        DispatchQueue.main.async { self.isDepthActive = false }
    }

    /// 原因調べ用の情報をプレビューに出す（sessionQueue で呼ぶ）
    private func showDiagnostic() {
        let device = videoInput?.device
        let dims = device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let auth: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: auth = "許可"
        case .denied: auth = "拒否"
        case .restricted: auth = "制限"
        default: auth = "未確認"
        }
        let info = [
            "カメラの映像が届きません",
            "カメラ: \(device?.localizedName ?? "なし")",
            "映像: \(dims.map { "\($0.width)×\($0.height)" } ?? "-")",
            "動作中: \(session.isRunning ? "はい" : "いいえ")",
            "中断: \(session.isInterrupted ? "はい" : "いいえ") \(lastInterruption ?? "")",
            "エラー: \(lastRuntimeError ?? "なし")",
            "入力 \(session.inputs.count)・出力 \(session.outputs.count)・接続 \(session.connections.count)",
            "カメラの許可: \(auth)",
        ].joined(separator: "\n")
        DispatchQueue.main.async { self.diagnostic = info }
    }

    /// セッションが中断されたときの理由を記録する
    @objc private func sessionWasInterrupted(_ note: Notification) {
        let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
        let reason: String
        switch raw {
        case 1: reason = "1 アプリが裏に回った"
        case 2: reason = "2 マイクを別のアプリが使用中"
        case 3: reason = "3 カメラを別のアプリが使用中"
        case 4: reason = "4 ほかのアプリも前面にある（PiP など）"
        case 5: reason = "5 本体が熱いなど"
        default: reason = raw.map { "\($0)" } ?? "不明"
        }
        sessionQueue.async { self.lastInterruption = reason }
    }

    /// セッションのエラーを記録し、止まっていれば動かし直す
    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        sessionQueue.async {
            self.lastRuntimeError = error.map { "\($0.code) \($0.localizedDescription)" } ?? "不明"
            if !self.session.isRunning && !self.isDual { self.session.startRunning() }
        }
    }

    /// sessionQueue で呼ぶ
    private func configure(position: AVCaptureDevice.Position, wantDepth: Bool) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo
        // ほかのアプリが画面に出ている（ピクチャ・イン・ピクチャの動画など）とき、
        // iOS は「複数のアプリが前面にある」とみなしてカメラを止める（iPhone 13 で理由 4 の中断が起きた）。
        // 対応していれば、その状態でもカメラを使えるようにする
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }

        guard let device = Self.camera(at: position, wantDepth: wantDepth, wantRaw: wantsRawCamera),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        videoInput = input

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput), session.canAddOutput(photoOutput) else { return false }
        session.addOutput(videoOutput)
        session.addOutput(photoOutput)

        depthOutput.isFilteringEnabled = true   // 穴やノイズをならした距離をもらう
        depthOutput.alwaysDiscardsLateDepthData = true
        depthOutput.setDelegate(self, callbackQueue: videoQueue)

        applyFormat(for: device, wantDepth: wantDepth)
        setUpConnections(for: device)
        return true
    }

    /// 写真用の最高画質の設定と、距離を測る設定を切り替える。
    /// 距離を測れる設定は写真の最大解像度が下がる（4800万画素で撮れない）ため、フラッシュモードのときだけ使う。
    /// sessionQueue の beginConfiguration〜commitConfiguration の中で呼ぶ
    private func applyFormat(for device: AVCaptureDevice, wantDepth: Bool) {
        var depthOn = false
        if wantDepth {
            if !hasDepthOutput, session.canAddOutput(depthOutput) {
                session.addOutput(depthOutput)
                hasDepthOutput = true
            }
            if hasDepthOutput, let format = Self.bestDepthFormat(of: device),
               let depthFormat = Self.bestDepthDataFormat(of: format) {
                depthOn = setFormat(format, depthFormat: depthFormat, on: device)
            }
        }
        if !depthOn {
            if hasDepthOutput {
                session.removeOutput(depthOutput)
                hasDepthOutput = false
            }
            // 写真がいちばん大きく撮れる設定を自分で選ぶ（標準の設定だと 1200万画素になる機種がある）
            let photoFormatSet = !useStandardFormat && (Self.bestPhotoFormat(of: device)
                .map { setFormat($0, depthFormat: nil, on: device) } ?? false)
            if !photoFormatSet {
                session.sessionPreset = .photo
            }
        }

        isDepthOn = depthOn
        depthOutput.connection(with: .depthData)?.isEnabled = depthOn
        refreshPhotoDepthDelivery()
        if !depthOn {
            frameLock.lock()
            _latestDepth = nil
            _subjectDistance = nil
            frameLock.unlock()
        }
        DispatchQueue.main.async { self.isDepthActive = depthOn }
    }

    private func setFormat(_ format: AVCaptureDevice.Format, depthFormat: AVCaptureDevice.Format?,
                           on device: AVCaptureDevice) -> Bool {
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            if let depthFormat { device.activeDepthDataFormat = depthFormat }
            device.unlockForConfiguration()
            return true
        } catch {
            return false
        }
    }

    /// 写真がいちばん大きく撮れる設定（映像は 30fps 以上・8 ビットのもの）。
    /// 同じ大きさなら、プレビューの映像が 1920×1440 に近いものを選ぶ
    private static func bestPhotoFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let target: Int32 = 1920 * 1440
        let eightBit: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let candidates = device.formats.filter { format in
            eightBit.contains(CMFormatDescriptionGetMediaSubType(format.formatDescription))
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        return candidates.max { a, b in
            (photoArea(a), -abs(videoArea(a) - target)) < (photoArea(b), -abs(videoArea(b) - target))
        }
    }

    private static func photoArea(_ f: AVCaptureDevice.Format) -> Int32 {
        f.supportedMaxPhotoDimensions.map { $0.width * $0.height }.max() ?? 0
    }

    private static func videoArea(_ f: AVCaptureDevice.Format) -> Int32 {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return d.width * d.height
    }

    /// 写真にも距離を付けるか。対応しているかどうかは設定を変えた後に決まるので、
    /// 設定の確定後にもう一度呼ぶ（sessionQueue で呼ぶ）
    private func refreshPhotoDepthDelivery() {
        photoOutput.isDepthDataDeliveryEnabled = isDepthOn && photoOutput.isDepthDataDeliverySupported
    }

    /// 距離を測れる設定のうち、写真がいちばん大きく撮れるもの
    private static func bestDepthFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { format in
            !format.supportedDepthDataFormats.isEmpty
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
                // プレビューが重くならないよう、映像は 1920×1440 程度までにする
                && videoArea(format) <= 1920 * 1440
        }
        return candidates.max { a, b in
            (photoArea(a), videoArea(a)) < (photoArea(b), videoArea(b))
        }
    }

    /// 距離データの形式のうち、いちばん細かいもの（距離そのものの形式を優先）
    private static func bestDepthDataFormat(of format: AVCaptureDevice.Format) -> AVCaptureDevice.Format? {
        let depthTypes: Set<OSType> = [kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DepthFloat16]
        func width(_ f: AVCaptureDevice.Format) -> Int32 {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription).width
        }
        func isDepth(_ f: AVCaptureDevice.Format) -> Bool {
            depthTypes.contains(CMFormatDescriptionGetMediaSubType(f.formatDescription))
        }
        let formats = format.supportedDepthDataFormats
        return formats.filter(isDepth).max { width($0) < width($1) }
            ?? formats.max { width($0) < width($1) }
    }

    /// sessionQueue で呼ぶ
    private func setUpConnections(for device: AVCaptureDevice) {
        // 写真はそのカメラの最大解像度・画質優先で撮る（初期値だと小さめになる）
        if let largest = device.activeFormat.supportedMaxPhotoDimensions
            .max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = largest
        }
        photoOutput.maxPhotoQualityPrioritization = .quality

        if let connection = videoOutput.connection(with: .video) {
            // 画面は縦向き固定なので、映像も縦向きでもらう
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = device.position == .front
            }
        }

        var depthRotated = false
        if let connection = depthOutput.connection(with: .depthData),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            depthRotated = true
        }
        frameLock.lock()
        _depthRotatedByConnection = depthRotated
        frameLock.unlock()

        applyZoom(on: device)

        DispatchQueue.main.async {
            self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        }
    }

    // MARK: - ズーム（一眼のズームレンズのように、一定の速さでググッと動かす）

    private static func zoomMultiplier(for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) { return device.displayVideoZoomFactorMultiplier }
        switch device.deviceType {
        case .builtInDualWideCamera, .builtInTripleCamera: return 0.5
        default: return 1
        }
    }

    private static func zoomLimits(of device: AVCaptureDevice) -> (min: CGFloat, max: CGFloat) {
        let multiplier = zoomMultiplier(for: device)
        let maxFactor = min(device.maxAvailableVideoZoomFactor, maxDisplayZoom / multiplier)
        return (device.minAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, maxFactor))
    }

    /// カメラや設定を変えたあと、前と同じ倍率に戻す（sessionQueue で呼ぶ）
    private func applyZoom(on device: AVCaptureDevice) {
        let multiplier = Self.zoomMultiplier(for: device)
        let limits = Self.zoomLimits(of: device)
        frameLock.lock()
        let desired = _desiredZoom
        frameLock.unlock()
        let factor = min(max(desired / multiplier, limits.min), limits.max)
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        }
        DispatchQueue.main.async {
            self.zoomMultiplier = multiplier
            self.zoomDevice = device
            self.zoomRange = (limits.min * multiplier)...(limits.max * multiplier)
            self.zoom = factor * multiplier
        }
    }

    /// ズームレバー：押している間、一定の速さで望遠（+1）／広角（-1）へ動かす。0 で止める
    func zoomLever(_ direction: Int) {
        sessionQueue.async {
            guard let device = self.videoInput?.device,
                  (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if direction == 0 {
                device.cancelVideoZoomRamp()
            } else {
                let limits = Self.zoomLimits(of: device)
                // rate は「1 秒に何段（2 倍）進むか」。ゆっくり一定の速さで動かす
                device.ramp(toVideoZoomFactor: direction > 0 ? limits.max : limits.min, withRate: 1.0)
            }
        }
    }

    /// 0.5× / 1× / 2× などのボタン：その倍率まで、一定の速さで動かす
    func zoom(to display: CGFloat) {
        ramp(to: display, rate: 1.6)
    }

    /// ズームの目盛りを指でなぞったとき：その倍率へ素早く追いかける（レンズのリングを回す感覚）
    func scrubZoom(to display: CGFloat) {
        ramp(to: display, rate: 8)
    }

    private func ramp(to display: CGFloat, rate: Float) {
        sessionQueue.async {
            guard let device = self.videoInput?.device,
                  (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            let limits = Self.zoomLimits(of: device)
            let factor = min(max(display / Self.zoomMultiplier(for: device), limits.min), limits.max)
            device.ramp(toVideoZoomFactor: factor, withRate: rate)
        }
    }

    /// 今の倍率を画面に出すため、こまめに読む（ズームは少しずつ動くので）
    private func startZoomTracking() {
        guard zoomTimer == nil else { return }
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let device = self.zoomDevice else { return }
            let current = device.videoZoomFactor * self.zoomMultiplier
            if abs(current - self.zoom) > 0.004 {
                self.zoom = current
                self.frameLock.lock()
                self._desiredZoom = current
                self.frameLock.unlock()
            }
        }
    }

    /// 距離を使うときの背面は、距離を測れるカメラを優先する（LiDAR → デュアルカメラ → 広角）。
    /// それ以外の背面は、超広角（0.5×）までズームできるデュアルカメラを、
    /// 広角カメラと同じ大きさの写真が撮れるときだけ使う（画質を落とさないため）
    private static func camera(at position: AVCaptureDevice.Position, wantDepth: Bool,
                               wantRaw: Bool = false) -> AVCaptureDevice? {
        if position == .back && !wantDepth && wantRaw {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
        if position == .back && !wantDepth {
            let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            if let dual = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) {
                let dualArea = bestPhotoFormat(of: dual).map { photoArea($0) } ?? 0
                let wideArea = wide.flatMap { bestPhotoFormat(of: $0) }.map { photoArea($0) } ?? 0
                if dualArea >= wideArea { return dual }
            }
            return wide
        }
        let types: [AVCaptureDevice.DeviceType] = position == .back && wantDepth
            ? [.builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return nil
    }

    // MARK: - モードとカメラの切り替え

    private func updateDepth() {
        guard isConfigured else { return }
        let wantDepth = mode.usesDepth
        sessionQueue.async {
            guard let current = self.videoInput?.device else { return }
            self.session.beginConfiguration()
            let device = self.useCamera(at: current.position, wantDepth: wantDepth) ?? current
            self.applyFormat(for: device, wantDepth: wantDepth)
            self.setUpConnections(for: device)
            self.session.commitConfiguration()
            self.refreshPhotoDepthDelivery()
        }
    }

    /// 使うカメラを切り替える（同じなら何もしない）。切り替えたカメラ、または今のカメラを返す。
    /// sessionQueue の beginConfiguration〜commitConfiguration の中で呼ぶ
    private func useCamera(at position: AVCaptureDevice.Position, wantDepth: Bool) -> AVCaptureDevice? {
        let chosen = useSimpleCamera
            ? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            : Self.camera(at: position, wantDepth: wantDepth, wantRaw: wantsRawCamera)
        guard let device = chosen else {
            return videoInput?.device
        }
        if device.uniqueID == videoInput?.device.uniqueID { return device }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return videoInput?.device }
        // 前の設定のままだと新しいカメラで使えないことがあるので、いったん標準に戻す
        session.sessionPreset = .photo
        if let current = videoInput { session.removeInput(current) }
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        } else if let current = videoInput {
            session.addInput(current)
        }
        return videoInput?.device
    }

    func switchCamera() {
        guard status == .running else { return }
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        let wantDepth = mode.usesDepth
        sessionQueue.async {
            self.session.beginConfiguration()
            guard let active = self.useCamera(at: next, wantDepth: wantDepth) else {
                self.session.commitConfiguration()
                return
            }
            self.applyFormat(for: active, wantDepth: wantDepth)
            self.setUpConnections(for: active)
            self.session.commitConfiguration()
            self.refreshPhotoDepthDelivery()
            let now = active.position
            DispatchQueue.main.async {
                self.position = now
                self.updateTorch()
            }
        }
    }

    // MARK: - 撮影

    /// シャッター（画面のボタン・音量ボタン）。写真なら撮影、動画なら録画の開始／停止
    func shutterPressed() {
        switch captureKind {
        case .photo: capture()
        case .video: isRecording ? stopRecording() : startRecording()
        }
    }

    // MARK: - 動画

    /// 撮影中の画面と同じフィルタをかけた映像を録画する（多重露光はフィルムの色で録る）
    func startRecording() {
        guard status == .running, !isRecording, !isSaving else { return }
        var options = baseOptions
        if options.mode == .double { options.mode = .film }
        // 端末を横にして撮ったら、横向きで再生されるようにする
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        let transform = CGAffineTransform(rotationAngle: (angle - 90) * .pi / 180)
        isRecording = true
        recordingStartedAt = Date()
        frameLock.lock()
        _wantsRecording = true
        frameLock.unlock()

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            self.sessionQueue.async {
                if granted && !self.hasAudio { self.addMicrophone() }
                let withAudio = self.hasAudio
                self.recordingQueue.async {
                    self.frameLock.lock()
                    let wants = self._wantsRecording
                    self._recordingActive = wants
                    self.frameLock.unlock()
                    guard wants else { return }
                    self.recorder = nil
                    self.recordingOptions = options
                    self.recordingTransform = transform
                    self.recordingWithAudio = withAudio
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingStartedAt = nil
        isSaving = true
        frameLock.lock()
        _wantsRecording = false
        _recordingActive = false
        frameLock.unlock()

        recordingQueue.async {
            let recorder = self.recorder
            let lastFrame = self.lastRecordedFrame
            self.recorder = nil
            self.recordingOptions = nil
            self.lastRecordedFrame = nil
            guard let recorder else {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.message = "短すぎて保存できませんでした"
                }
                return
            }
            recorder.finish { url in
                let thumbnail = lastFrame.flatMap { self.previewImage(of: $0) }
                guard let url else {
                    DispatchQueue.main.async {
                        self.isSaving = false
                        self.message = "動画の保存に失敗しました"
                    }
                    return
                }
                self.saveVideoToLibrary(url)
                DispatchQueue.main.async {
                    if let thumbnail {
                        self.lastPhoto = thumbnail
                        self.lastPhotoFile = nil
                    }
                    self.isSaving = false
                }
            }
        }
    }

    /// マイクをセッションに追加する（初めて録画するときだけ。sessionQueue で呼ぶ）
    private func addMicrophone() {
        guard let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) && session.canAddOutput(audioOutput) {
            session.addInput(input)
            audioOutput.setSampleBufferDelegate(self, queue: recordingQueue)
            session.addOutput(audioOutput)
            hasAudio = true
        }
        session.commitConfiguration()
    }

    private func saveVideoToLibrary(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.message = "写真への保存が許可されていません（設定 → フィルムカメラ → 写真）"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
            }) { success, _ in
                DispatchQueue.main.async {
                    self.message = success ? "動画を保存しました" : "動画の保存に失敗しました"
                }
            }
        }
    }

    // MARK: - 写真

    func capture() {
        guard status == .running, !isSaving else { return }
        if isDual {
            captureDual()
            return
        }
        if mode == .double && burstInterval > 0 && exposures.isEmpty {
            startBurst()
            return
        }
        isSaving = true
        shotCount += 1
        shoot(fast: false)
    }

    /// 多重露光の連射：決めた間隔で、決めた枚数を続けて撮る（届いた順に重ねる）
    private func startBurst() {
        let count = exposureCount
        let interval = burstInterval
        let fast = interval < Self.fastBurstLimit
        isSaving = true
        isBursting = true
        for index in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(index)) {
                guard self.isBursting else { return }
                self.shotCount += 1
                self.shoot(fast: fast)
            }
        }
    }

    /// 1 枚撮る。fast は連射用（1200万画素・速さ優先）
    private func shoot(fast: Bool) {
        var options = baseOptions
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        let mirrored = position == .front
        // 本物のフラッシュ（連射のときは間に合わないので光らせない）
        let useFlash = light && !fast

        // フラッシュ：距離を測れる設定だと 1200万画素でしか撮れないので、
        // 直前のプレビューで測った距離を借りて、撮影の瞬間だけ 4800万画素の設定に切り替える
        let borrowDepth = options.mode.usesDepth && isDepthActive && position == .back
        if borrowDepth, let depth = latestDepth {
            // プレビューは縦向き（90°）。写真の向き（angle）に合わせて回す
            let radians = -(angle - 90) * .pi / 180
            options.depth = depth.transformed(by: CGAffineTransform(rotationAngle: radians))
            options.subjectDistance = subjectDistance
        }

        sessionQueue.async {
            if borrowDepth { self.switchToFullResolutionForCapture() }
            if let connection = self.photoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = mirrored
                }
            }
            // RAW：iPhone の処理（ノイズ除去・合成・トーンカーブ）の前のセンサーのデータをもらう
            let rawFormat = options.mode.usesRaw
                ? self.photoOutput.availableRawPhotoPixelFormatTypes
                    .first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
                : nil
            if options.mode.usesRaw && rawFormat == nil && !self.toldRawUnavailable {
                self.toldRawUnavailable = true
                DispatchQueue.main.async {
                    self.message = "このカメラでは RAW で撮れないため、処理済みの写真から作ります"
                }
            }
            let settings = rawFormat.map { AVCapturePhotoSettings(rawPixelFormatType: $0) }
                ?? AVCapturePhotoSettings()
            if rawFormat != nil {
                // RAW は何枚もの合成ができないので、速さ優先にする（大きさはカメラの決まった大きさになる）
                settings.photoQualityPrioritization = .speed
            } else if fast {
                settings.maxPhotoDimensions = self.fastPhotoDimensions()
                settings.photoQualityPrioritization = .speed
            } else {
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                settings.photoQualityPrioritization = .quality
            }
            if useFlash && self.photoOutput.supportedFlashModes.contains(.on) {
                settings.flashMode = .on
            }
            if options.mode.usesDepth && !borrowDepth && self.photoOutput.isDepthDataDeliveryEnabled {
                settings.isDepthDataDeliveryEnabled = true
                settings.embedsDepthDataInPhoto = false
            }
            let processor = PhotoCaptureProcessor { [weak self] data, depth, distance, isRaw in
                self?.finishCapture(data: data, depth: depth, distance: distance, isRaw: isRaw,
                                    options: options, id: settings.uniqueID)
                if borrowDepth {
                    // 撮り終わったら距離を測る設定に戻す（その間にモードが変わっていれば戻さない）
                    DispatchQueue.main.async {
                        if self?.mode.usesDepth == true { self?.updateDepth() }
                    }
                }
            }
            self.inFlight[settings.uniqueID] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    /// 連射用の写真の大きさ（1200万画素前後。なければいちばん小さいもの）。sessionQueue で呼ぶ
    private func fastPhotoDimensions() -> CMVideoDimensions {
        let all = videoInput?.device.activeFormat.supportedMaxPhotoDimensions ?? []
        let limit: Int32 = 4032 * 3024
        return all.filter { $0.width * $0.height <= limit }
            .max { $0.width * $0.height < $1.width * $1.height }
            ?? all.min { $0.width * $0.height < $1.width * $1.height }
            ?? photoOutput.maxPhotoDimensions
    }

    /// 前後同時撮影：外と内を同時に撮り、内カメラを左上に重ねて 1 枚にする
    private func captureDual() {
        isSaving = true
        shotCount += 1
        var options = baseOptions
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        sessionQueue.async {
            self.dual.capture(angle: angle) { back, front in
                guard let back else {
                    DispatchQueue.main.async {
                        self.isSaving = false
                        self.message = "撮影に失敗しました"
                    }
                    return
                }
                options.front = front
                self.renderAndSave(back, options: options)
            }
        }
    }

    /// 背面の広角カメラ・最大解像度の設定に切り替え、露出が落ち着くまで少し待つ（sessionQueue で呼ぶ）
    private func switchToFullResolutionForCapture() {
        session.beginConfiguration()
        if let device = useCamera(at: .back, wantDepth: false) {
            applyFormat(for: device, wantDepth: false)
            setUpConnections(for: device)
        }
        session.commitConfiguration()
        refreshPhotoDepthDelivery()
        guard let device = videoInput?.device else { return }
        let deadline = Date().addingTimeInterval(1.0)
        Thread.sleep(forTimeInterval: 0.15)
        while device.isAdjustingExposure && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func finishCapture(data: Data?, depth: CIImage?, distance: CGFloat?, isRaw: Bool,
                               options: LookOptions, id: Int64) {
        sessionQueue.async { self.inFlight[id] = nil }

        if isRaw, let data, let developed = Self.developRaw(data) {
            var options = options
            options.fromRaw = true
            renderAndSave(developed, options: options)
            return
        }

        guard let data,
              let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            DispatchQueue.main.async {
                self.isBursting = false
                self.isSaving = false
                self.message = "撮影に失敗しました"
            }
            return
        }

        if options.mode == .double {
            addExposure(image, options: options)
            return
        }

        var options = options
        if let depth {
            options.depth = depth
            options.subjectDistance = distance
        }
        // 分割は、並べた全体の長い辺が約 6000px になるようにコマの大きさを決める（1 コマは最大 4000px）
        if options.mode == .contact {
            let layout = options.contactLayout
            let tileLong = 24000 / CGFloat(max(3 * layout.columns, 4 * layout.rows))
            options.contactTileLongSide = min(4000, tileLong)
        }
        renderAndSave(image, options: options)
    }

    /// RAW（DNG）を、トーンカーブや局所的な明るさ補正をかけずに現像する。
    /// 出てくるのは光の量に比例した明るさで、白より明るい部分も 1 を超えた値として残る
    private static func developRaw(_ data: Data) -> CIImage? {
        guard let raw = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") else { return nil }
        raw.boostAmount = 0
        raw.boostShadowAmount = 0
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        // ノイズは少しだけ残し、粒子となじませる
        if raw.isLuminanceNoiseReductionSupported {
            raw.luminanceNoiseReductionAmount = min(raw.luminanceNoiseReductionAmount, 0.35)
        }
        guard let image = raw.outputImage else { return nil }
        // 撮影日時やレンズの情報を引き継ぐ（RAW 専用の情報は外す）
        var properties: [String: Any] = [:]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary] {
                if let value = all[key as String] { properties[key as String] = value }
            }
        }
        return image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .settingProperties(properties)
    }

    /// フィルタをかけて写真アプリに保存する
    private func renderAndSave(_ image: CIImage, options: LookOptions) {
        processingQueue.async {
            // 撮影日時やカメラ・レンズの情報を残す（向きは適用済みなので「そのまま」にする）
            var properties = image.properties
            properties[kCGImagePropertyOrientation as String] = 1
            let output = LookRenderer.resizeForSaving(LookRenderer.apply(image, options: options))
                .settingProperties(properties)
            // 10 ビットの HEIF で保存する（JPEG の 8 ビットより階調がなめらかで、ファイルも小さい）
            let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
            let quality = kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption
            let file: (data: Data, type: String)
            if let heif = try? self.ciContext.heif10Representation(of: output, colorSpace: p3,
                                                                   options: [quality: 0.85]) {
                file = (heif, "public.heic")
            } else if let jpeg = self.ciContext.jpegRepresentation(of: output, colorSpace: p3,
                                                                    options: [quality: 0.90]) {
                file = (jpeg, "public.jpeg")
            } else {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.message = "画像の作成に失敗しました"
                }
                return
            }
            let thumbnail = self.previewImage(of: output)
            let mode = options.mode.title
            DispatchQueue.main.async {
                self.lastPhotoFile = (file.data, file.type, mode)
                self.lastPhoto = thumbnail
                self.isSaving = false
                Task { @MainActor in
                    AlbumStore.shared.addIfAutomatic(data: file.data, type: file.type, thumbnail: thumbnail, mode: mode)
                }
            }
            self.saveToLibrary(file.data, type: file.type)
        }
    }

    /// 多重露光の 1 枚を取っておき、枚数がそろったら重ねて保存する。
    /// プレビューで毎コマ重ねるので、小さくした画像も作っておく
    private func addExposure(_ image: CIImage, options: LookOptions) {
        processingQueue.async {
            let long = max(image.extent.width, image.extent.height)
            let scale = min(1, 1600 / max(long, 1))
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let preview = self.ciContext.createCGImage(small, from: small.extent).map { CIImage(cgImage: $0) }
            DispatchQueue.main.async {
                self.exposures.append(image)
                if let preview { self.exposurePreviews.append(preview) }
                let total = self.exposureCount
                if self.exposures.count >= total {
                    var options = options
                    options.overlays = Array(self.exposures.dropLast())
                    options.exposureTotal = self.exposures.count
                    let last = self.exposures[self.exposures.count - 1]
                    self.isBursting = false
                    self.discardExposures()
                    self.renderAndSave(last, options: options)
                } else if !self.isBursting {
                    self.isSaving = false
                    self.message = "\(self.exposures.count) / \(total) 枚。重ねたいものを写して、もう一度シャッターを"
                }
            }
        }
    }

    /// 撮った写真を画面で見る用に縮小する（大きな写真をそのまま読み込まないため）
    private func previewImage(of image: CIImage) -> UIImage? {
        let long = max(image.extent.width, image.extent.height)
        guard long > 0 else { return nil }
        let scale = min(1, 2400 / long)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent,
                                               format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    private func saveToLibrary(_ data: Data, type: String) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.message = "写真への保存が許可されていません（設定 → フィルムカメラ → 写真）"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = type
                request.addResource(with: .photo, data: data, options: options)
            }) { success, _ in
                if !success {
                    DispatchQueue.main.async { self.message = "写真の保存に失敗しました" }
                }
            }
        }
    }

    /// 距離データを、メートル単位の 1 チャンネル画像と、画面中央の被写体までの距離にする
    static func depthImage(from depthData: AVDepthData) -> (image: CIImage, subject: CGFloat?) {
        let converted = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = converted.depthDataMap
        let image = CIImage(cvPixelBuffer: map, options: [.colorSpace: NSNull()])
        return (image, centerDistance(of: map))
    }

    /// 画面中央（縦横それぞれ真ん中 40%）で測れた距離の中央値。
    /// カメラのフラッシュが被写体に合わせて光の強さを決めるのと同じ考え方
    private static func centerDistance(of map: CVPixelBuffer) -> CGFloat? {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var values: [Float] = []
        values.reserveCapacity(width * height / 6)
        for y in (height * 3 / 10)..<(height * 7 / 10) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in (width * 3 / 10)..<(width * 7 / 10) {
                let v = row[x]
                if v.isFinite && v > 0.1 { values.append(v) }
            }
        }
        guard values.count > 10 else { return nil }
        values.sort()
        let median = CGFloat(values[values.count / 2])
        return min(max(median, 0.4), 4.0)
    }
}

// MARK: - 映像フレームと距離の受け取り

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            // 音声は recordingQueue で届く
            if recordingOptions != nil { recorder?.append(audio: sampleBuffer) }
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        frameLock.lock()
        _latestFrame = frame
        _frameCount += 1
        let depth = _latestDepth
        let subject = _subjectDistance
        // 録画中で、前のコマの書き込みが終わっていれば、このコマを書き込む
        let shouldRecord = _recordingActive && !_renderingFrame
        if shouldRecord { _renderingFrame = true }
        frameLock.unlock()
        guard shouldRecord else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        recordingQueue.async {
            defer {
                self.frameLock.lock()
                self._renderingFrame = false
                self.frameLock.unlock()
            }
            guard var options = self.recordingOptions else { return }
            if options.mode.usesDepth {
                options.depth = depth
                options.subjectDistance = subject
            }
            let look = LookRenderer.apply(frame, options: options)
            // 動画の大きさはフィルタ後の大きさ（6分割は元と縦横比が変わる）
            if self.recorder == nil {
                self.recorder = VideoRecorder(size: look.extent.size, transform: self.recordingTransform,
                                              withAudio: self.recordingWithAudio)
            }
            self.recorder?.append(look, at: time, context: self.videoContext)
            self.lastRecordedFrame = look
        }
    }
}

extension CameraModel: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                         didOutput depthData: AVDepthData,
                         timestamp: CMTime,
                         connection: AVCaptureConnection) {
        let measured = Self.depthImage(from: depthData)
        var depth = measured.image
        frameLock.lock()
        let rotated = _depthRotatedByConnection
        frameLock.unlock()
        if !rotated {
            // センサーの向き（横）のままなので、映像に合わせて縦向きに回す
            depth = depth.oriented(.right)
        }
        frameLock.lock()
        _latestDepth = depth
        if let subject = measured.subject {
            // 毎コマ少しずつ追いかけ、明るさがちらつかないようにする
            _subjectDistance = _subjectDistance.map { $0 * 0.8 + subject * 0.2 } ?? subject
        }
        frameLock.unlock()
    }
}

// MARK: - 写真の受け取り役

private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    /// データ・距離・被写体までの距離・RAW（DNG）か
    private let completion: (Data?, CIImage?, CGFloat?, Bool) -> Void

    init(completion: @escaping (Data?, CIImage?, CGFloat?, Bool) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil else {
            completion(nil, nil, nil, false)
            return
        }
        // 写真と同じ向きにそろえた距離
        var depth: CIImage?
        var distance: CGFloat?
        if var depthData = photo.depthData {
            if let raw = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32,
               let orientation = CGImagePropertyOrientation(rawValue: raw) {
                depthData = depthData.applyingExifOrientation(orientation)
            }
            let measured = CameraModel.depthImage(from: depthData)
            depth = measured.image
            distance = measured.subject
        }
        completion(photo.fileDataRepresentation(), depth, distance, photo.isRawPhoto)
    }
}
