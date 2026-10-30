import CoreGraphics
import CoreImage

/// 撮影モード（見え方）
enum LookMode: String, CaseIterable, Identifiable {
    /// フィルタなし（iPhone の標準カメラと同じ色）
    case standard
    case film
    case flash
    case warmFlash
    case compact
    case iwai
    case cross
    case harinezumi
    case warmHarinezumi
    case double
    case contact
    /// RAW（iPhone の処理の前のデータ）から現像し、映画フィルムのような階調にする
    case cinema

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "標準"
        case .film: return "フィルム"
        case .flash: return "フラッシュ"
        case .warmFlash: return "暖フラッシュ"
        case .compact: return "コンデジ"
        case .iwai: return "岩井俊二風"
        case .cross: return "クロス"
        case .harinezumi: return "ハリネズミ"
        case .warmHarinezumi: return "暖ハリネズミ"
        case .double: return "多重露光"
        case .contact: return "分割"
        case .cinema: return "シネマ"
        }
    }

    /// 距離（LiDAR など）を使うモードか
    var usesDepth: Bool { self == .flash || self == .warmFlash }

    /// RAW で撮るモードか
    var usesRaw: Bool { self == .cinema }

    var caption: String {
        switch self {
        case .standard: return "フィルタなし：iPhone の標準カメラと同じ色"
        case .film: return "低いコントラスト・暖かい白・にじむ光"
        case .flash: return "直射フラッシュのコンデジ写真"
        case .warmFlash: return "暖かい色のフラッシュ写真"
        case .iwai: return "澄んだ青空・紺の影・にじむ光"
        case .cross: return "暖色と寒色がぶつかる、濃く硬い色"
        case .compact: return "2000年代のコンデジ：飛びやすい白・鮮やかな青・カリッとした輪郭"
        case .harinezumi: return "トイデジ風：白飛び・マゼンタ・どぎつい緑"
        case .warmHarinezumi: return "トイデジ風：琥珀色・濃い青空・暗い四隅"
        case .double: return "何枚かを 1 枚に重ねる"
        case .contact: return "いくつものフィルタで同時に撮って1枚に"
        case .cinema: return "RAW から現像：映画フィルムのような階調・赤いにじみ・粒子"
        }
    }
}

/// フィルタにかけるときの設定
struct LookOptions {
    var mode: LookMode
    var dateStamp: Bool
    /// 距離（メートル）。写真や映像と同じ向き。大きさはそろっていなくてよい
    var depth: CIImage? = nil
    /// 主な被写体までの距離（メートル）。フラッシュの光がちょうどよく当たる距離になる
    var subjectDistance: CGFloat? = nil
    /// 多重露光で先に撮った分（向きは適用済み）。今の像に重ねる
    var overlays: [CIImage] = []
    /// 多重露光で最終的に重ねる枚数（重ねすぎて白くならないよう、1 枚ずつの暗さを決める）
    var exposureTotal: Int = 2
    /// 分割で、1 コマの長い辺（ピクセル）。nil なら元の画像に収まる大きさ（プレビュー・動画用）
    var contactTileLongSide: CGFloat? = nil
    /// 分割の並べ方と、コマごとのフィルタ（左上から右へ。足りない分は前から繰り返す）
    var contactLayout: ContactLayout = .c2x3
    var contactModes: [LookMode] = ContactLayout.defaultModes
    /// 分割の各コマに、フィルタ名を小さく入れるか
    var contactLabels = true
    /// 前後同時撮影の内カメラの画像。あれば同じフィルタをかけて左上に小さく重ねる
    var front: CIImage? = nil
    /// 粒子（グレイン）の模様をずらす量。毎フレーム変えると粒子が動いて見える
    var grainSeed: CGPoint = CGPoint(x: CGFloat.random(in: 0..<512), y: CGFloat.random(in: 0..<512))
    /// RAW から現像した、トーンカーブのかかっていない（光の量に比例した）画像か。
    /// false のときは iPhone が処理した写真・映像として、白飛びした明るさを推定で広げてから使う
    var fromRaw = false
}

/// 分割の並べ方（横に何コマ × 縦に何コマ）
enum ContactLayout: String, CaseIterable, Identifiable {
    case c2x1, c1x2, c2x2, c3x1, c1x3, c3x2, c2x3, c3x3, c4x2, c2x4

    var id: String { rawValue }

    var columns: Int {
        switch self {
        case .c1x2, .c1x3: return 1
        case .c2x1, .c2x2, .c2x3, .c2x4: return 2
        case .c3x1, .c3x2, .c3x3: return 3
        case .c4x2: return 4
        }
    }

    var rows: Int {
        switch self {
        case .c2x1, .c3x1: return 1
        case .c1x2, .c2x2, .c3x2, .c4x2: return 2
        case .c1x3, .c2x3, .c3x3: return 3
        case .c2x4: return 4
        }
    }

    var count: Int { columns * rows }

    /// 「横×縦」の表記
    var title: String { "\(columns)×\(rows)" }

    /// 分割で選べるフィルタ（重ねたり分割したりするモードは除く）
    static let selectableModes: [LookMode] = [.standard, .film, .flash, .warmFlash, .compact, .iwai, .cross, .harinezumi, .warmHarinezumi, .cinema]

    static let defaultModes: [LookMode] = [.film, .flash, .iwai, .cross, .harinezumi, .warmHarinezumi,
                                           .warmFlash, .film, .iwai]
}
