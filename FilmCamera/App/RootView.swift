import SwiftUI

/// アプリの最初の画面：共有アルバムが主役。カメラは右下のボタンを押したときだけ、全画面で開く。
/// 起動直後はレンズの絞りが開く起動画面を重ねる
struct RootView: View {
    @ObservedObject private var album = AlbumStore.shared
    @StateObject private var camera = CameraModel()
    @State private var showingCamera = false
    @State private var showingGames = false
    @State private var showingSplash = true
    @State private var showingPuni = false
    @ObservedObject private var invites = PuniInvites.shared

    var body: some View {
        ZStack {
            AlbumView(store: album, onOpenCamera: { showingCamera = true }, onOpenGames: { showingGames = true })
            if showingSplash {
                SplashView {
                    withAnimation(.easeOut(duration: 0.4)) { showingSplash = false }
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .preferredColorScheme(.light)
        .fullScreenCover(isPresented: $showingGames) {
            GameHubView(initialImage: camera.lastPhoto)
        }
        // Game Center の対戦の招待を受けたとき：ぷにぷにシューターを直接開く
        .fullScreenCover(isPresented: $showingPuni) {
            PuniGameView()
        }
        .onChange(of: invites.openPuni) { _, open in
            guard open else { return }
            invites.openPuni = false
            guard !invites.puniVisible else { return }
            let delay = showingCamera || showingGames ? 0.7 : 0
            showingCamera = false
            showingGames = false
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { showingPuni = true }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            ContentView(camera: camera)
                .preferredColorScheme(.dark)
        }
        // 招待を受けたときや通知をタップしたとき：カメラを閉じてアルバムに戻る
        .onChange(of: album.showAlbum) { _, show in
            guard show else { return }
            showingCamera = false
            album.showAlbum = false
        }
        // 写真の「このフィルタで撮る」：写真の画面が閉じるのを待ってからカメラを開く（モードはカメラ側で受け取る）
        .onChange(of: album.requestedMode) { _, title in
            guard title != nil, !showingCamera else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showingCamera = true }
        }
        // ロック画面などのウィジェットの「カメラ」
        .onChange(of: album.openCamera) { _, open in
            guard open else { return }
            album.openCamera = false
            showingCamera = true
        }
        .onOpenURL { album.open($0) }
        // EXILIM から受け取って、まだ共有アルバムに送れていない写真があれば送る
        .task {
            guard ExilimPending.count > 0 else { return }
            try? await Task.sleep(for: .seconds(5))
            await ExilimPending.flush()
        }
        .onAppear {
            // ウィジェットからアプリが起動したとき（画面ができる前に受け取っている）
            if album.openCamera || album.requestedMode != nil {
                album.openCamera = false
                showingCamera = true
            }
        }
    }
}
