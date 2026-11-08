import GameKit
import SwiftUI
import UIKit

/// ぷにぷにシューターのオンライン対戦（Game Center）。
/// それぞれ自分の容器で遊び、相手の容器は小さく見える。16 以上の玉を作ると、相手の容器に「おじゃま玉」（1 と 2）が降る。
/// 先にゲームオーバーになったほうの負け。送るのは「玉の場所と数字（1 秒に 5 回）」「おじゃま玉の数」「負けた」だけなので、
/// 離れていても遅れが気になりにくい。
/// Game Center を使うには、Apple Developer の App ID と App Store Connect のアプリで Game Center をオンにしておく
@MainActor
final class PuniVersus: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Game Center へのサインイン・相手さがし
        case searching
        /// 始まるまでの 3・2・1
        case countdown(Int)
        case playing
        case finished(won: Bool, reason: String)
        case failed(String)
    }

    /// 相手の容器の玉（x・y は容器の幅を 1000 とした場所。送るデータを小さくするため整数）
    struct MiniBlob: Codable {
        var l: Int
        var x: Int
        var y: Int
    }

    enum Message: Codable {
        case board(blobs: [MiniBlob], score: Int, left: Double, right: Double)
        case garbage(Int)
        case lost
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var opponentName = "相手"
    @Published private(set) var opponentBlobs: [MiniBlob] = []
    @Published private(set) var opponentScore = 0
    @Published private(set) var opponentGauges: (left: Double, right: Double) = (0, 0)
    /// これから自分の容器に降ってくるおじゃま玉の数
    @Published private(set) var incoming = 0

    /// 対戦が始まったとき（ゲームを最初からにする）
    var onStart: (() -> Void)?
    /// おじゃま玉を降らせるとき
    var onGarbage: ((Int) -> Void)?
    /// 相手が負けたとき（自分のゲームを止める）
    var onWin: (() -> Void)?

    private var match: GKMatch?
    private var boardTimer: Double = 0
    private var incomingTimer: Double = 0

    var isActive: Bool {
        switch phase {
        case .countdown, .playing: return true
        default: return false
        }
    }

    // MARK: - 始める・やめる

    /// Game Center にサインインして、相手をさがす（友だちを招待するか、自動で組む）
    func start() {
        guard phase == .idle || isFinished else { return }
        reset()
        phase = .searching
        PuniInvites.shared.signIn { [weak self] ok, detail in
            guard let self, self.phase == .searching else { return }
            if ok {
                self.showMatchmaker()
            } else {
                self.phase = .failed("Game Center にサインインできませんでした。iPhone の「設定」→「Game Center」でサインインしてください。\(detail)")
            }
        }
    }

    /// 友だちからの招待を受けたとき（招待のリンク・通知から）
    func accept(_ invite: GKInvite) {
        if isActive { leave() }
        reset()
        phase = .searching
        guard let controller = GKMatchmakerViewController(invite: invite) else {
            phase = .failed("招待を開けませんでした")
            return
        }
        controller.matchmakerDelegate = self
        Self.present(controller)
    }

    func leave() {
        match?.disconnect()
        match?.delegate = nil
        match = nil
        reset()
        phase = .idle
    }

    private var isFinished: Bool {
        switch phase {
        case .finished, .failed: return true
        default: return false
        }
    }

    private func reset() {
        opponentBlobs = []
        opponentScore = 0
        opponentGauges = (0, 0)
        incoming = 0
        boardTimer = 0
        incomingTimer = 0
    }

    private func showMatchmaker() {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        guard let controller = GKMatchmakerViewController(matchRequest: request) else {
            phase = .failed("相手さがしの画面を開けませんでした")
            return
        }
        controller.matchmakerDelegate = self
        Self.present(controller)
    }

    private func begin(_ match: GKMatch) {
        self.match = match
        match.delegate = self
        opponentName = match.players.first?.displayName ?? "相手"
        reset()
        onStart?()
        Task { @MainActor in
            for count in [3, 2, 1] {
                phase = .countdown(count)
                try? await Task.sleep(for: .seconds(1))
                guard self.match != nil else { return }
            }
            phase = .playing
        }
    }

    // MARK: - ゲームから呼ぶ

    /// 毎コマ：自分の容器を 1 秒に 5 回送る、たまったおじゃま玉を降らせる
    func tick(_ dt: Double, game: PuniGame) {
        guard phase == .playing else { return }
        boardTimer -= dt
        if boardTimer <= 0 {
            boardTimer = 0.2
            send(.board(blobs: game.miniSnapshot(), score: game.score,
                        left: game.leftGauge, right: game.rightGauge), reliable: false)
        }
        if incoming > 0 {
            incomingTimer -= dt
            if incomingTimer <= 0 {
                let count = incoming
                incoming = 0
                onGarbage?(count)
            }
        }
    }

    /// 自分の玉がくっついたとき。16 以上ならおじゃま玉を送る（先に、自分に来ているおじゃま玉を打ち消す）
    func merged(level: Int) {
        guard phase == .playing, level >= 4 else { return }
        var count = min(level - 3, 6)
        let cancel = min(count, incoming)
        incoming -= cancel
        count -= cancel
        if count > 0 { send(.garbage(count), reliable: true) }
    }

    /// 自分がゲームオーバーになったとき
    func lost() {
        guard phase == .playing else { return }
        send(.lost, reliable: true)
        phase = .finished(won: false, reason: "先に両方のゲージがいっぱいになりました")
    }

    private func send(_ message: Message, reliable: Bool) {
        guard let match, let data = try? JSONEncoder().encode(message) else { return }
        // 届かなくてもよいデータは 1000 バイトまで。大きいときは確実に届く送り方にする
        let mode: GKMatch.SendDataMode = reliable || data.count > 900 ? .reliable : .unreliable
        try? match.sendData(toAllPlayers: data, with: mode)
    }

    private func receive(_ data: Data) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        switch message {
        case let .board(blobs, score, left, right):
            opponentBlobs = blobs
            opponentScore = score
            opponentGauges = (left, right)
        case let .garbage(count):
            guard phase == .playing else { return }
            incoming += count
            // 少し待ってから降らせる（その間に大きい玉を作れば打ち消せる）
            incomingTimer = 2.0
        case .lost:
            guard phase == .playing || isCountdown else { return }
            phase = .finished(won: true, reason: "\(opponentName) のゲージが両方いっぱいになりました")
            onWin?()
        }
    }

    private var isCountdown: Bool {
        if case .countdown = phase { return true }
        return false
    }

    private func opponentLeft() {
        guard isActive else { return }
        phase = .finished(won: true, reason: "\(opponentName) との通信が切れました")
        onWin?()
    }

    // MARK: - 画面を出す

    static func present(_ controller: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene.windows.first?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }
}

extension PuniVersus: GKMatchmakerViewControllerDelegate {
    nonisolated func matchmakerViewControllerWasCancelled(_ viewController: GKMatchmakerViewController) {
        Task { @MainActor in
            viewController.dismiss(animated: true)
            if self.phase == .searching { self.phase = .idle }
        }
    }

    nonisolated func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            viewController.dismiss(animated: true)
            self.phase = .failed("相手をさがせませんでした。\(message)")
        }
    }

    nonisolated func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFind match: GKMatch) {
        Task { @MainActor in
            viewController.dismiss(animated: true)
            self.begin(match)
        }
    }
}

extension PuniVersus: GKMatchDelegate {
    nonisolated func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        Task { @MainActor in self.receive(data) }
    }

    nonisolated func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        guard state == .disconnected else { return }
        Task { @MainActor in self.opponentLeft() }
    }

    nonisolated func match(_ match: GKMatch, didFailWithError error: Error?) {
        Task { @MainActor in self.opponentLeft() }
    }
}

/// Game Center のサインインと、友だちからの招待の受け取り（アプリの起動時から待つ）。
/// 招待を受けると、ぷにぷにシューターの画面を開いて対戦に入る
@MainActor
final class PuniInvites: NSObject, ObservableObject, GKLocalPlayerListener {
    static let shared = PuniInvites()

    /// 受けた招待（ぷにぷにシューターの画面が受け取って対戦に入る）
    @Published var pendingInvite: GKInvite?
    /// ぷにぷにシューターの画面を開いてほしいとき
    @Published var openPuni = false
    /// ぷにぷにシューターの画面が出ているか
    var puniVisible = false

    private var loginController: UIViewController?
    private var registered = false
    private var waiting: [(Bool, String) -> Void] = []
    private var started = false

    /// アプリの起動時に呼ぶ。サインインの画面は出さず（対戦を始めるときに出す）、サインイン済みなら招待を待つ
    func start() {
        guard !started else { return }
        started = true
        GKLocalPlayer.local.authenticateHandler = { [weak self] controller, error in
            Task { @MainActor in
                guard let self else { return }
                if let controller {
                    self.loginController = controller
                    // 対戦を始めようとしているときだけ、サインインの画面を出す
                    if !self.waiting.isEmpty { PuniVersus.present(controller) }
                } else if GKLocalPlayer.local.isAuthenticated {
                    self.loginController = nil
                    if !self.registered {
                        self.registered = true
                        GKLocalPlayer.local.register(self)
                    }
                    self.finish(true, "")
                } else {
                    self.finish(false, error?.localizedDescription ?? "")
                }
            }
        }
    }

    /// サインインする（済んでいればすぐ）。done はメインで呼ぶ
    func signIn(_ done: @escaping (Bool, String) -> Void) {
        start()
        if GKLocalPlayer.local.isAuthenticated {
            done(true, "")
            return
        }
        waiting.append(done)
        if let loginController {
            PuniVersus.present(loginController)
        }
    }

    private func finish(_ ok: Bool, _ detail: String) {
        let list = waiting
        waiting = []
        for done in list { done(ok, detail) }
    }

    nonisolated func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        Task { @MainActor in
            self.pendingInvite = invite
            if !self.puniVisible { self.openPuni = true }
        }
    }
}
