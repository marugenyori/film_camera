import CloudKit
import SwiftUI
import UIKit

@main
struct FilmCameraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// 共有アルバムの招待（iCloud のリンク）を受け取るため、シーンの受け取り役を差し込む。
/// コメントの通知のため、iCloud からの音の出ないプッシュも受け取る
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AlbumNotifier.shared.start()
        return true
    }

    /// 共有アルバムに変更があったとき（iCloud の見張りから）
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            await AlbumNotifier.shared.catchUp(notify: true)
            completionHandler(.newData)
        }
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// アプリが閉じていた状態で招待のリンクを開いたとき
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { @MainActor in AlbumStore.shared.accept(metadata) }
        }
        // ロック画面などのウィジェットから開かれたとき
        if let url = connectionOptions.urlContexts.first?.url {
            Task { @MainActor in AlbumStore.shared.open(url) }
        }
    }

    /// アプリを開いている状態で、ウィジェットから開かれたとき
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        Task { @MainActor in AlbumStore.shared.open(url) }
    }

    /// アプリに戻ってきたとき、プッシュが届かなかった分の反応も確かめる
    func sceneDidBecomeActive(_ scene: UIScene) {
        Task { await AlbumNotifier.shared.catchUp(notify: true) }
    }

    /// アプリを開いている状態で招待のリンクを開いたとき
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in AlbumStore.shared.accept(cloudKitShareMetadata) }
    }
}
