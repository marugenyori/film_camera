import SwiftUI

/// 隠しゲームの入口（倍率の黒い小窓を長押しすると開く）
struct GameHubView: View {
    /// ジュエル塗り絵で最初に使う写真
    let initialImage: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var playing: Game?

    enum Game: String, Identifiable {
        case jewel, candy, romance, chameleon, hakoniwa, civ, mart, puni
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            ScrollView {
            VStack(spacing: 14) {
                Text("ひみつのゲーム")
                    .font(.title2.weight(.heavy))
                    .padding(.top, 40)
                gameButton(title: "ぷにぷにシューター", subtitle: "ぷにぷにの玉を撃って、同じ色をくっつけて大きくしよう",
                           systemImage: "circle.hexagongrid.fill", colors: [.pink, .orange]) { playing = .puni }
                gameButton(title: "まちかどマート", subtitle: "商品を運んで棚に並べ、レジでお会計。お店を大きくしよう",
                           systemImage: "cart.fill", colors: [.yellow, .orange]) { playing = .mart }
                gameButton(title: "ジュエル塗り絵", subtitle: "宝石を並べ替えて絵を完成させる",
                           systemImage: "diamond.fill", colors: [.cyan, .purple]) { playing = .jewel }
                gameButton(title: "キャンディ・マッチ", subtitle: "3 つそろえて消す、特別なキャンディつき",
                           systemImage: "heart.fill", colors: [.pink, .orange]) { playing = .candy }
                gameButton(title: "放課後メモリーズ", subtitle: "2000年代のギャルゲー風・恋愛アドベンチャー",
                           systemImage: "envelope.open.fill", colors: [.purple, .pink]) { playing = .romance }
                gameButton(title: "かくれカメレオン", subtitle: "体に色を塗って背景にとけこむ、お絵描きかくれんぼ",
                           systemImage: "lizard.fill", colors: [.green, .teal]) { playing = .chameleon }
                gameButton(title: "ちいさな箱庭", subtitle: "地面を塗って家や木を置く。人や動物が歩きまわる",
                           systemImage: "house.lodge.fill", colors: [.mint, .blue]) { playing = .hakoniwa }
                gameButton(title: "ふたりの文明", subtitle: "2 人で一緒に文明を育てる。近くでも、離れていても",
                           systemImage: "globe.asia.australia.fill", colors: [.orange, .indigo]) { playing = .civ }
                Button("カメラに戻る") { dismiss() }
                    .padding(.vertical, 24)
            }
            .padding(.horizontal, 24)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $playing) { game in
            switch game {
            case .jewel: JewelGameView(initialImage: initialImage)
            case .candy: CandyGameView()
            case .romance: RomanceGameView()
            case .chameleon: ChameleonGameView(initialImage: initialImage)
            case .hakoniwa: HakoniwaGameView()
            case .civ: CivGameView()
            case .mart: MartGameView()
            case .puni: PuniGameView()
            }
        }
    }

    private func gameButton(title: String, subtitle: String, systemImage: String,
                            colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
