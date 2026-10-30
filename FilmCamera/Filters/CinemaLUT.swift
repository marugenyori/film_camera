import Foundation
import simd

/// シネマモードの階調と色を、3D の色の表（LUT）にまとめたもの。
/// 入力は「光の量に比例した明るさ（0〜range）を 1/encodingGamma 乗して 0〜1 に詰めた値」、
/// 出力は画面に出す明るさ（リニア、0〜1）。表は最初に使うときに 1 回だけ作る
enum CinemaLUT {
    /// 表の一辺の大きさ
    static let size = 64
    /// 扱う明るさの上限（中間の灰色 0.18 の約 44 倍、5.5 段上まで）
    static let range: CGFloat = 8
    static let encodingGamma: CGFloat = 2.4

    /// RAW から現像した像用
    static let raw: Data = make(fromRaw: true)
    /// iPhone が処理した写真・プレビュー用（白飛びした明るさを推定で広げてから同じ処理をする）
    static let processed: Data = make(fromRaw: false)

    private static func make(fromRaw: Bool) -> Data {
        let n = size
        let top = Float(n - 1)
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        // 赤がいちばん速く変わり、次に緑、最後に青の順に並べる
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let encoded = SIMD3<Float>(Float(r), Float(g), Float(b)) / top
                    let k = Float(encodingGamma)
                    var x = Float(range) * SIMD3<Float>(powf(encoded.x, k), powf(encoded.y, k), powf(encoded.z, k))
                    if !fromRaw { x = expand(x) }
                    let out = look(x)
                    values[index] = out.x
                    values[index + 1] = out.y
                    values[index + 2] = out.z
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 処理済みの写真は明るい部分が 1 で頭打ちになっているので、1 に近いほど大きく広げて
    /// 光の量に比例した明るさに近づける（0.18 → 0.21、0.5 → 0.8、1 → 4）
    private static func expand(_ x: SIMD3<Float>) -> SIMD3<Float> {
        let c = simd_min(x, SIMD3(repeating: 1))
        return c / (SIMD3(repeating: 1) - 0.75 * c)
    }

    private static let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// 映画のフィルムのような S 字の階調：暗部はなめらかに沈み、明るい部分は肩でゆっくり白に近づく
    private static func filmic(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let a = v * (2.51 * v + 0.03)
        let b = v * (2.43 * v + 0.59) + 0.14
        return simd_clamp(a / b, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 1 色分の処理（光の量に比例した明るさ → 画面に出す明るさ）
    private static func look(_ scene: SIMD3<Float>) -> SIMD3<Float> {
        // 中間の灰色（0.18）が、画面でちょうど中間の明るさになるよう少し暗くしてから階調をかける
        let e = simd_max(scene * 0.8, SIMD3(repeating: 0))
        let lum = simd_dot(e, luma)

        // 色ごとに階調をかけると、明るい色は白へ寄り、色味もフィルムのようにずれる。
        // 明るさだけにかけると色は保たれる。両方を混ぜる
        let perChannel = filmic(e)
        let mapped = filmic(SIMD3(repeating: lum)).x
        let kept = lum > 1e-6 ? e * (mapped / lum) : SIMD3(repeating: 0)
        var c = simd_mix(kept, perChannel, SIMD3(repeating: 0.65))

        // 明るい部分ほど色を薄くして、白飛びの縁で色が残らないようにする
        var y = simd_dot(c, luma)
        let roll = smoothstep(0.55, 1.0, y)
        c = simd_mix(c, SIMD3(repeating: y), SIMD3(repeating: roll * 0.6))

        // 中間の明るさの色を少し濃く（明るい部分は濃くしない）
        c = SIMD3(repeating: y) + (c - SIMD3(repeating: y)) * (1 + 0.10 * (1 - roll))

        // 影はわずかに青緑、明るい部分はわずかに暖かく（映写用フィルムの色の傾向）
        y = simd_dot(c, luma)
        let shadow = 1 - smoothstep(0.0, 0.2, y)
        let high = smoothstep(0.3, 0.9, y)
        let cool: SIMD3<Float> = shadow * SIMD3<Float>(-0.06, 0.0, 0.05)
        let warm: SIMD3<Float> = high * SIMD3<Float>(0.03, 0.005, -0.04)
        c *= SIMD3<Float>(repeating: 1) + cool + warm

        // 黒をほんの少し浮かせる（フィルムの黒は真っ黒にならない）
        c = c * 0.995 + 0.0025
        return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }
}
