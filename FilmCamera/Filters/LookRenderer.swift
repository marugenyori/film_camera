import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// プレビューの1フレームにも、保存する写真にも同じ処理をかける。
/// 粒子の大きさや周辺減光の範囲は画像サイズからの割合で決めるので、
/// 画面で見えている雰囲気のまま保存される。
enum LookRenderer {

    static func apply(_ input: CIImage, options: LookOptions, date: Date = Date()) -> CIImage {
        // 前後同時撮影：外カメラと内カメラにそれぞれ同じフィルタをかけ、内カメラを左上に重ねる
        // （6分割と多重露光は、前後同時ではフィルムの色にする）
        if let front = options.front {
            var single = options
            single.front = nil
            single.dateStamp = false
            if single.mode == .contact || single.mode == .double { single.mode = .film }
            var frontOptions = single
            frontOptions.depth = nil
            frontOptions.subjectDistance = nil
            var out = pictureInPicture(main: apply(input, options: single, date: date),
                                       inset: apply(front, options: frontOptions, date: date))
            if options.dateStamp { out = stamp(date, on: out) }
            return out
        }

        // 原点を (0, 0) にそろえる
        let image = input.transformed(by: CGAffineTransform(
            translationX: -input.extent.minX, y: -input.extent.minY))

        var out: CIImage
        switch options.mode {
        case .standard: out = image
        case .film: out = film(image, seed: options.grainSeed)
        case .flash: out = flash(image, depth: options.depth, subject: options.subjectDistance)
        case .warmFlash: out = flash(image, depth: options.depth, subject: options.subjectDistance, warm: true)
        case .compact: out = compact(image)
        case .iwai: out = iwai(image, seed: options.grainSeed)
        case .cross: out = cross(image)
        case .harinezumi: out = harinezumi(image)
        case .warmHarinezumi: out = warmHarinezumi(image)
        case .double: out = multiple(image, overlays: options.overlays,
                                     total: options.exposureTotal, seed: options.grainSeed)
        case .contact: out = contactSheet(image, options: options)
        case .cinema: out = cinema(image, fromRaw: options.fromRaw, seed: options.grainSeed)
        }
        if options.dateStamp { out = stamp(date, on: out) }
        return out
    }

    // MARK: - 前後同時撮影

    /// 外カメラの写真の左上に、内カメラの写真を角の丸い白フチ付きで小さく重ねる
    private static func pictureInPicture(main: CIImage, inset: CIImage) -> CIImage {
        let extent = main.extent
        let insetExtent = inset.extent
        guard insetExtent.width > 0, insetExtent.height > 0 else { return main }

        let targetWidth = shortSide(extent) * 0.30
        let scale = targetWidth / insetExtent.width
        let small = inset
            .transformed(by: CGAffineTransform(translationX: -insetExtent.minX, y: -insetExtent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = small.extent.width
        let h = small.extent.height
        let margin = shortSide(extent) * 0.04
        let border = shortSide(extent) * 0.008
        let radius = w * 0.08
        // 左上（Core Image は下が原点）
        let origin = CGPoint(x: extent.minX + margin, y: extent.maxY - margin - h)

        let photoRect = CGRect(origin: origin, size: CGSize(width: w, height: h))
        let photo = small.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        let frameRect = photoRect.insetBy(dx: -border, dy: -border)

        let frame = roundedRect(frameRect, radius: radius + border,
                                color: CIColor(red: 1, green: 1, blue: 1))
        let mask = roundedRect(photoRect, radius: radius, color: CIColor(red: 1, green: 1, blue: 1))
        let clip = CIFilter.blendWithMask()
        clip.inputImage = photo
        clip.backgroundImage = frame
        clip.maskImage = mask
        let card = (clip.outputImage ?? photo).cropped(to: frameRect)

        // うっすら影を落として浮かせる
        let shadow = roundedRect(frameRect, radius: radius + border,
                                 color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            .applyingGaussianBlur(sigma: Double(border * 2))
            .transformed(by: CGAffineTransform(translationX: 0, y: -border))
        return card.composited(over: shadow.composited(over: main)).cropped(to: extent)
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(radius)
        generator.color = color
        return generator.outputImage?.cropped(to: rect) ?? CIImage.empty()
    }

    // MARK: - 分割（1 回のシャッターで、いくつものフィルタ）

    /// 同じ 1 枚にコマごとのフィルタをかけ、指定の並べ方で 1 枚にする（フィルムのコンタクトシート風）
    private static func contactSheet(_ image: CIImage, options: LookOptions) -> CIImage {
        let long = longSide(image.extent)
        guard long > 0 else { return image }
        let columns = options.contactLayout.columns
        let rows = options.contactLayout.rows
        let modes = options.contactModes.isEmpty ? ContactLayout.defaultModes : options.contactModes
        // 指定がなければ、並べた全体が元の画像くらいの大きさに収まるようにする（プレビュー・動画用）
        let target = options.contactTileLongSide ?? long / CGFloat(max(columns, rows))
        let scale = min(1, target / long)
        // 大きく縮めるのでギザギザが出ないよう、画質の良い縮小（Lanczos）を使う
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = image
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1
        let scaled = lanczos.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let tile = scaled.transformed(by: CGAffineTransform(
            translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        let w = tile.extent.width
        let h = tile.extent.height
        let gap = (min(w, h) * 0.025).rounded()
        let sheetRect = CGRect(x: 0, y: 0,
                               width: CGFloat(columns) * w + CGFloat(columns + 1) * gap,
                               height: CGFloat(rows) * h + CGFloat(rows + 1) * gap)
        var sheet = CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.06)).cropped(to: sheetRect)

        for index in 0..<(columns * rows) {
            let mode = modes[index % modes.count]
            var tileOptions = LookOptions(mode: mode, dateStamp: false)
            tileOptions.grainSeed = options.grainSeed
            var look = apply(tile, options: tileOptions)
            if options.contactLabels {
                look = look.composited(over: label(mode.title, in: look.extent))
            }
            let column = index % columns
            let row = index / columns
            // Core Image は下が原点なので、上の段ほど y が大きい
            let x = gap + CGFloat(column) * (w + gap)
            let y = gap + CGFloat(rows - 1 - row) * (h + gap)
            sheet = look.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: sheet)
        }
        return sheet.cropped(to: sheetRect)
    }

    /// 1 コマの左下に置く、モード名の小さな白い文字
    private static func label(_ text: String, in extent: CGRect) -> CIImage {
        let generator = CIFilter.textImageGenerator()
        generator.text = text
        generator.fontName = "HiraginoSans-W6"
        generator.fontSize = Float(shortSide(extent) * 0.06)
        generator.scaleFactor = 1
        guard let glyphs = generator.outputImage else { return CIImage.empty() }
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.92)).cropped(to: glyphs.extent)
        let colored = CIFilter.blendWithAlphaMask()
        colored.inputImage = white
        colored.backgroundImage = CIImage.empty()
        colored.maskImage = glyphs
        guard let textImage = colored.outputImage else { return CIImage.empty() }
        let margin = shortSide(extent) * 0.04
        let moved = textImage.transformed(by: CGAffineTransform(
            translationX: extent.minX + margin, y: extent.minY + margin))
        // 明るい写真でも読めるよう、うっすら影を付ける
        let shadow = CIFilter.blendWithAlphaMask()
        shadow.inputImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.6)).cropped(to: moved.extent)
        shadow.backgroundImage = CIImage.empty()
        shadow.maskImage = moved
        let soft = (shadow.outputImage ?? CIImage.empty())
            .applyingGaussianBlur(sigma: Double(shortSide(extent) * 0.006))
        return moved.composited(over: soft)
    }

    // MARK: - フィルム風（写ルンです・ネガフィルム）

    /// 黒が締まりきらない低いコントラスト、クリーム〜ピンクがかったハイライト、
    /// 緑っぽい影、くすんだ緑、ハイライトのふんわりしたにじみ、細かい粒子
    private static func film(_ image: CIImage, seed: CGPoint) -> CIImage {
        let extent = image.extent

        let controls = CIFilter.colorControls()
        controls.inputImage = toSRGB(exposure(image, ev: 0.15))
        controls.saturation = 0.80
        controls.contrast = 0.95

        // 色ごとのトーンカーブ（入力 x に対する 3 次式）
        // 赤：ハイライトを持ち上げる／緑：影を持ち上げ、ハイライトを抑える／青：ハイライトを抑える
        let toned = polynomial(controls.outputImage ?? image,
                               r: (0.03, 0.87, 0.25, -0.17),
                               g: (0.045, 0.94, -0.02, -0.07),
                               b: (0.04, 0.82, 0.06, -0.04))

        // 粒子は画質が落ちて見えるため入れない（`grain` は残してある）
        let grained = diffusion(toned, radius: longSide(extent) * 0.006, amount: 0.10)
        return toLinear(vignette(detail(grained), strength: 0.28, inner: 0.42))
    }

    // MARK: - シネマ（RAW から現像する映画フィルム風）

    /// 光の量に比例した明るさ（RAW を現像しただけの像）に、映画フィルムのような処理をかける。
    /// 1. 白を超える明るい光のまわりに赤橙のにじみ（ハレーション：フィルムの裏で光が跳ね返ってできる）
    /// 2. 暗部はなめらかに沈み、明るい部分は白飛びせずゆっくり白に近づく階調（3D の色の表 = LUT でかける）
    /// 3. 中間の明るさほど目立つ粒子と、弱い周辺減光
    private static func cinema(_ image: CIImage, fromRaw: Bool, seed: CGPoint) -> CIImage {
        let extent = image.extent
        let haloed = halation(image, threshold: fromRaw ? 1.0 : 0.85, amount: 0.45)

        // LUT は 0〜1 の入力しか扱えないので、0〜8 の明るさを 1/2.4 乗で 0〜1 に詰めてから引く
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = haloed
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: CinemaLUT.range, y: CinemaLUT.range, z: CinemaLUT.range, w: 1)
        let scaled = colorMatrix(clamp.outputImage ?? haloed,
                                 r: 1 / CinemaLUT.range, g: 1 / CinemaLUT.range, b: 1 / CinemaLUT.range,
                                 bias: (0, 0, 0))
        let gamma = CIFilter.gammaAdjust()
        gamma.inputImage = scaled
        gamma.power = Float(1 / CinemaLUT.encodingGamma)

        let cube = CIFilter.colorCube()
        cube.inputImage = gamma.outputImage ?? scaled
        cube.cubeDimension = Float(CinemaLUT.size)
        cube.cubeData = fromRaw ? CinemaLUT.raw : CinemaLUT.processed
        let graded = (cube.outputImage ?? image).cropped(to: extent)

        let grained = grain(toSRGB(graded), amount: 0.055, seed: seed)
        return toLinear(vignette(grained, strength: 0.16, inner: 0.5))
    }

    /// 明るい部分だけを取り出してぼかし、赤橙に色を付けて足す（光の量のまま足すので、強い光ほど広くにじむ）
    private static func halation(_ image: CIImage, threshold: CGFloat, amount: CGFloat) -> CIImage {
        let extent = image.extent
        // 明るさ（輝度）から threshold を引いた分だけ残す
        let luma = CIFilter.colorMatrix()
        luma.inputImage = image
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luma.rVector = weights
        luma.gVector = weights
        luma.bVector = weights
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        luma.biasVector = CIVector(x: -threshold, y: -threshold, z: -threshold, w: 0)
        let positive = CIFilter.colorClamp()
        positive.inputImage = luma.outputImage
        positive.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
        positive.maxComponents = CIVector(x: 16, y: 16, z: 16, w: 1)
        guard let bright = positive.outputImage else { return image }

        // 狭いにじみと広いにじみを重ねる
        let long = longSide(extent)
        let near = bright.clampedToExtent().applyingGaussianBlur(sigma: Double(long * 0.004))
        let far = bright.clampedToExtent().applyingGaussianBlur(sigma: Double(long * 0.014))
        let add = CIFilter.additionCompositing()
        add.inputImage = glowTint(near, r: amount * 0.9, g: amount * 0.22, b: amount * 0.06)
        add.backgroundImage = glowTint(far, r: amount * 0.5, g: amount * 0.10, b: amount * 0.02)
        guard let glow = add.outputImage?.cropped(to: extent) else { return image }

        let sum = CIFilter.additionCompositing()
        sum.inputImage = glow
        sum.backgroundImage = image
        return (sum.outputImage ?? image).cropped(to: extent)
    }

    /// にじみに色を付ける。足し合わせても不透明度が 1 を超えないよう、不透明度は 0 にする
    private static func glowTint(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: g, y: 0, z: 0, w: 0)
        m.bVector = CIVector(x: b, y: 0, z: 0, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return m.outputImage ?? image
    }

    // MARK: - フラッシュ風（2000年代のコンデジの直射フラッシュ）

    /// 手前の被写体が平たく明るく照らされ、白は飛び気味、黒はつぶれ、
    /// 背景は少し暗く沈む。色は濃く、くっきり
    private static func flash(_ image: CIImage, depth: CIImage?, subject: CGFloat?,
                              warm: Bool = false) -> CIImage {
        let extent = image.extent
        // 人が来やすい、中央より少し上を中心にする（Core Image は下が原点）
        let center = CGPoint(x: extent.midX, y: extent.midY + extent.height * 0.05)

        let bright: CIImage
        let dark: CIImage
        let mask: CIImage
        if let depth, let falloff = flashFalloff(depth: depth, subject: subject ?? 1.0, guide: image) {
            // 距離が分かるとき：近いものほど強く照らし、遠くは暗く沈める（本物のフラッシュと同じ）
            bright = exposure(image, ev: 0.6)
            dark = exposure(image, ev: -1.4)
            let beam = radialMask(center: center, extent: extent,
                                  inner: shortSide(extent) * 0.35, outer: longSide(extent) * 0.9,
                                  edge: 0.6)
            let multiply = CIFilter.multiplyCompositing()
            multiply.inputImage = falloff
            multiply.backgroundImage = beam
            mask = (multiply.outputImage ?? falloff).cropped(to: extent)
        } else {
            // 距離が分からないとき：中央を近いとみなし、外側ほど暗くする
            bright = exposure(image, ev: 0.15)
            dark = exposure(image, ev: -1.2)
            mask = radialMask(center: center, extent: extent,
                              inner: shortSide(extent) * 0.22, outer: longSide(extent) * 0.80,
                              edge: 0)
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = bright
        blend.backgroundImage = dark
        blend.maskImage = mask
        let lit = blend.outputImage ?? image

        let controls = CIFilter.colorControls()
        controls.inputImage = toSRGB(lit)
        controls.saturation = 1.05
        controls.contrast = 1.02

        // 黒をつぶし、白を飛ばす
        let punchy = toneCurve(controls.outputImage, [
            (0.00, 0.00), (0.20, 0.15), (0.50, 0.51), (0.80, 0.90), (1.00, 1.00),
        ])

        // ふつうはフラッシュ光のやや青白い色。暖フラッシュは電球や古いストロボのような黄〜橙
        let cool = warm
            ? colorMatrix(punchy, r: 1.07, g: 1.00, b: 0.84, bias: (0.02, 0.005, -0.01))
            : colorMatrix(punchy, r: 0.97, g: 1.00, b: 1.04, bias: (0, 0, 0.005))

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = cool
        sharpen.sharpness = 0.25
        let sharp = (sharpen.outputImage ?? cool).cropped(to: extent)

        let grained = sharp
        return toLinear(vignette(grained, strength: 0.12, inner: 0.55))
    }

    /// 距離（メートル）から、フラッシュの光の当たり具合（1 = よく当たる、0 = 届かない）を作る。
    /// 本物のカメラと同じく、主な被写体（subject）にちょうどよく当たるよう強さを合わせ、
    /// そこから距離の 2 乗で弱める（被写体の 1.5 倍の距離で約半分、2 倍で 1/4、4 倍以上で届かない）。
    /// 距離の画像は粗いので、写真の輪郭に沿って拡大し、物の縁から光がはみ出さないようにする
    private static func flashFalloff(depth: CIImage, subject: CGFloat, guide: CIImage) -> CIImage? {
        let d = depth.extent
        guard d.width > 0, d.height > 0 else { return nil }
        let small = depth.transformed(by: CGAffineTransform(translationX: -d.minX, y: -d.minY))

        // 「被写体までの距離の何倍か」を 4 で割った値（0〜1）にし、3 色とも同じ値にする
        let normalize = CIFilter.colorMatrix()
        normalize.inputImage = small
        let k: CGFloat = 1.0 / (max(subject, 0.3) * 4)
        normalize.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        normalize.gVector = CIVector(x: k, y: 0, z: 0, w: 0)
        normalize.bVector = CIVector(x: k, y: 0, z: 0, w: 0)
        normalize.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        normalize.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = normalize.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let normalized = clamp.outputImage else { return nil }

        // 横軸は（距離 ÷ 被写体の距離）÷ 4。0.25 が被写体の位置
        let falloff = toneCurve(normalized, [
            (0.00, 1.00), (0.18, 1.00), (0.375, 0.45), (0.50, 0.25), (1.00, 0.00),
        ])

        // 距離が測れなかった所（0m 扱い）は「近い」と誤解して白く飛ぶので、光を当てない
        let valid = CIFilter.colorThreshold()
        valid.inputImage = normalized
        valid.threshold = 0.02
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = falloff
        multiply.backgroundImage = valid.outputImage ?? normalized
        let masked = (multiply.outputImage ?? falloff).cropped(to: small.extent)

        // 写真の明るさの輪郭を手がかりに拡大する
        let upsample = CIFilter.edgePreserveUpsample()
        upsample.inputImage = guide
        upsample.smallImage = masked
        upsample.spatialSigma = 3
        upsample.lumaSigma = 0.15
        return upsample.outputImage?.cropped(to: guide.extent)
    }

    /// 中央が 1、外側が edge になる円形のマスク
    private static func radialMask(center: CGPoint, extent: CGRect,
                                   inner: CGFloat, outer: CGFloat, edge: CGFloat) -> CIImage {
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(inner)
        gradient.radius1 = Float(outer)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
        gradient.color1 = CIColor(red: edge, green: edge, blue: edge)
        return (gradient.outputImage ?? CIImage(color: .white)).cropped(to: extent)
    }

    // MARK: - クロス（クロスプロセス風）

    /// 持ち主が気に入った「アンバランスな色」。初期のフラッシュの処理をそのまま残したもの。
    /// 色の調整をあえてリニアのまま行うので、暖色（床や木）はより黄色く、
    /// 影や奥は青く沈み、暖色と寒色がぶつかる濃く硬い色になる。粒子は入れない
    private static func cross(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let center = CGPoint(x: extent.midX, y: extent.midY + extent.height * 0.05)

        let bright = exposure(image, ev: 0.8)
        let dark = exposure(image, ev: -0.5)
        let mask = radialMask(center: center, extent: extent,
                              inner: shortSide(extent) * 0.30, outer: longSide(extent) * 0.95,
                              edge: 0)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = bright
        blend.backgroundImage = dark
        blend.maskImage = mask
        let lit = blend.outputImage ?? image

        let controls = CIFilter.colorControls()
        controls.inputImage = lit
        controls.saturation = 1.20
        controls.contrast = 1.08

        let punchy = toneCurve(controls.outputImage, [
            (0.00, 0.00), (0.20, 0.11), (0.50, 0.52), (0.80, 0.93), (1.00, 1.00),
        ])
        let cool = colorMatrix(punchy, r: 0.97, g: 1.00, b: 1.04, bias: (0, 0, 0.005))

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = cool
        sharpen.sharpness = 0.6
        let sharp = (sharpen.outputImage ?? cool).cropped(to: extent)
        return vignette(sharp, strength: 0.12, inner: 0.55)
    }

    // MARK: - デジタルハリネズミ風（トイデジ）

    /// 小さなトイデジカメ「Digital Harinezumi」の写り（持ち主が見せた馬の写真が目標）。
    /// 空は真っ白に飛び、明るい部分はピンク〜マゼンタ、影は青紫に沈んでほぼ黒、
    /// 緑や赤はどぎついほど濃く、輪郭はガリッと硬い。
    /// 本物は低画素でノイズも多いが、画質は落とさず色と光の癖だけをまねる
    private static func harinezumi(_ image: CIImage) -> CIImage {
        let extent = image.extent

        let controls = CIFilter.colorControls()
        controls.inputImage = toSRGB(exposure(image, ev: 0.35))
        controls.saturation = 1.45
        controls.contrast = 1.35

        // 黒をつぶし、白を飛ばす
        let punchy = toneCurve(controls.outputImage, [
            (0.00, 0.00), (0.15, 0.04), (0.50, 0.50), (0.80, 0.95), (1.00, 1.00),
        ])
        // 明るい部分は緑を抑えてマゼンタに、影と中間は青を持ち上げて青紫に
        let toned = polynomial(punchy,
                               r: (0.00, 0.95, 0.15, -0.08),
                               g: (0.00, 0.98, 0.05, -0.12),
                               b: (0.05, 1.05, -0.10, -0.02))

        // 安いデジカメの強い輪郭強調
        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = toned
        unsharp.radius = Float(max(1, longSide(extent) / 2000) * 2)
        unsharp.intensity = 0.8
        let crisp = (unsharp.outputImage ?? toned).cropped(to: extent)
        return toLinear(vignette(crisp, strength: 0.15, inner: 0.45))
    }

    /// 2000年代の CCD のコンデジの写り（持ち主が見せたファミレスの写真が目標）。
    /// 白は少し青みのある素っ気ない白で、照明や窓などの明るい所はすぐ真っ白に飛ぶ
    /// （ダイナミックレンジが狭い）。青がくっきり鮮やかに出て、影はつぶれすぎない。
    /// 輪郭はデジタルらしくカリッと強調するが、粒子やノイズは足さない（画質は落とさない）
    private static func compact(_ image: CIImage) -> CIImage {
        let extent = image.extent

        let controls = CIFilter.colorControls()
        controls.inputImage = toSRGB(exposure(image, ev: 0.25))
        controls.saturation = 1.1
        controls.contrast = 1.06

        // 中間はほぼそのまま、明るい所は早めに白へ張り付く
        let clipped = toneCurve(controls.outputImage, [
            (0.00, 0.02), (0.25, 0.23), (0.55, 0.58), (0.82, 0.96), (1.00, 1.00),
        ])
        // 少し寒色寄りの白（赤をわずかに引き、青を中間で持ち上げる）
        let toned = polynomial(clipped,
                               r: (0.00, 0.97, 0.03, -0.01),
                               g: (0.00, 1.00, 0.00, 0.00),
                               b: (0.01, 1.06, 0.00, -0.06))
        // 色の薄い所ほど彩度を上げ、青い服や看板の色をはっきりさせる
        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = toned
        vibrance.amount = 0.3

        // コンデジの画像処理らしい、細かく硬めの輪郭強調
        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = vibrance.outputImage ?? toned
        unsharp.radius = Float(max(1, longSide(extent) / 2000) * 1.5)
        unsharp.intensity = 0.6
        let crisp = (unsharp.outputImage ?? toned).cropped(to: extent)
        return toLinear(crisp)
    }

    /// ハリネズミのもう一つの写り（持ち主が見せたお城の写真が目標）。
    /// 石や木は琥珀〜オレンジに、空は濃い青のまま、白い雲は少しピンク、
    /// 四隅は暗く落ち、全体はやわらかめ。マゼンタの版と違い、中間を暖かくする
    private static func warmHarinezumi(_ image: CIImage) -> CIImage {
        let extent = image.extent

        let controls = CIFilter.colorControls()
        controls.inputImage = toSRGB(exposure(image, ev: 0.10))
        controls.saturation = 1.35
        controls.contrast = 1.15

        let curved = toneCurve(controls.outputImage, [
            (0.00, 0.00), (0.20, 0.12), (0.50, 0.50), (0.80, 0.88), (1.00, 0.98),
        ])
        // 中間は赤を足して青を引き（琥珀色）、白は緑を少し抑える（ピンクがかった雲）
        let toned = polynomial(curved,
                               r: (0.02, 1.05, 0.00, -0.08),
                               g: (0.00, 0.98, 0.00, -0.06),
                               b: (0.02, 0.92, 0.00, 0.00))

        let soft = diffusion(toned, radius: longSide(extent) * 0.004, amount: 0.06)
        return toLinear(vignette(soft, strength: 0.35, inner: 0.35))
    }

    // MARK: - 多重露光

    /// フィルムで同じコマに何回も露光したように、先に撮った分と今の像を「スクリーン」で重ねる
    /// （明るい部分が足し合わさり、暗い部分にはほかの像が透けて見える）。
    /// 重ねるほど明るくなりすぎるので、枚数に応じて 1 枚ずつ暗くしてから重ね、仕上げにフィルムの色をかける
    private static func multiple(_ image: CIImage, overlays: [CIImage], total: Int, seed: CGPoint) -> CIImage {
        guard !overlays.isEmpty else { return film(image, seed: seed) }
        let extent = image.extent
        let ev = Float(-0.35 * log2(Double(max(total, 2))))
        var combined = toSRGB(exposure(image, ev: ev))
        for overlay in overlays {
            let layer = toSRGB(exposure(fill(overlay, into: extent), ev: ev))
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = layer
            screen.backgroundImage = combined
            combined = (screen.outputImage ?? combined).cropped(to: extent)
        }
        return film(toLinear(combined), seed: seed)
    }

    /// 縦横比を保ったまま extent いっぱいに広げ、はみ出しは中央で切る
    static func fill(_ image: CIImage, into extent: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let scale = max(extent.width / e.width, extent.height / e.height)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = extent.minX - (scaled.extent.width - extent.width) / 2
        let dy = extent.minY - (scaled.extent.height - extent.height) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: extent)
    }

    // MARK: - 岩井俊二風（『リリイ・シュシュのすべて』のポスターのような色）

    /// 澄んだシアン寄りの青空、紺に沈む影（鉄塔や人のシルエット）、
    /// 白く光ってにじむ太陽まわり。全体をやや青緑に寄せ、色は淡くせずしっかり残す
    private static func iwai(_ image: CIImage, seed: CGPoint) -> CIImage {
        let extent = image.extent

        let controls = CIFilter.colorControls()
        controls.inputImage = toSRGB(exposure(image, ev: 0.30))
        controls.saturation = 1.10
        controls.contrast = 1.00

        // 赤を抑えて全体を青緑に寄せ、青は中間〜影で持ち上げて空を澄んだ青に、影を紺にする
        let toned = polynomial(controls.outputImage ?? image,
                               r: (0.00, 0.80, 0.12, -0.02),
                               g: (0.03, 0.96, 0.05, -0.04),
                               b: (0.07, 1.02, 0.00, -0.09))

        // 明るい空や光のまわりを大きくにじませる（細部はぼかさない）
        let glowing = diffusion(toned, radius: longSide(extent) * 0.020, amount: 0.28)
        return toLinear(detail(glowing))
    }

    // MARK: - 日付の写し込み（オレンジの文字）

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "''yy  M  d"
        return f
    }()

    private static func stamp(_ date: Date, on image: CIImage) -> CIImage {
        let extent = image.extent
        let text = CIFilter.textImageGenerator()
        text.text = stampFormatter.string(from: date)
        text.fontName = "DBLCDTempBlack"
        text.fontSize = Float(shortSide(extent) * 0.045)
        text.scaleFactor = 1
        guard let glyphs = text.outputImage else { return image }

        // 文字の形（アルファ）だけ使ってオレンジで塗る
        let orange = CIImage(color: CIColor(red: 1.0, green: 0.55, blue: 0.12))
            .cropped(to: glyphs.extent)
        let colored = CIFilter.blendWithAlphaMask()
        colored.inputImage = orange
        colored.backgroundImage = CIImage.empty()
        colored.maskImage = glyphs
        guard let label = colored.outputImage else { return image }

        // 右下に置き、少しにじませる
        let margin = shortSide(extent) * 0.05
        let moved = label.transformed(by: CGAffineTransform(
            translationX: extent.maxX - glyphs.extent.width - margin,
            y: extent.minY + margin))
        let glow = moved.applyingGaussianBlur(sigma: Double(shortSide(extent) * 0.004))
        return moved.composited(over: glow.composited(over: image)).cropped(to: extent)
    }

    // MARK: - 部品

    private static func grain(_ image: CIImage, amount: CGFloat, seed: CGPoint) -> CIImage {
        let extent = image.extent
        guard let random = CIFilter.randomGenerator().outputImage else { return image }

        // 画像が大きいほど粒を大きくして、見た目の粒の細かさをそろえる
        let scale = max(1, longSide(extent) / 1600)
        let noise = random
            .transformed(by: CGAffineTransform(translationX: seed.x, y: seed.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // 1画素ずつの白い点にならないよう、少しぼかして粒にする
            .applyingGaussianBlur(sigma: Double(scale * 0.6))
            .cropped(to: extent)

        // 白黒の、0.5 を中心にした弱いノイズにする
        // ぼかすと揺れ幅が小さくなるので、その分を補う
        let a = amount * 2
        let mono = CIFilter.colorMatrix()
        mono.inputImage = noise
        mono.rVector = CIVector(x: a, y: 0, z: 0, w: 0)
        mono.gVector = CIVector(x: a, y: 0, z: 0, w: 0)
        mono.bVector = CIVector(x: a, y: 0, z: 0, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        mono.biasVector = CIVector(x: 0.5 - a / 2, y: 0.5 - a / 2, z: 0.5 - a / 2, w: 1)

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = mono.outputImage
        blend.backgroundImage = image
        return (blend.outputImage ?? image).cropped(to: extent)
    }

    /// 周辺減光。inner は対角線の半分に対する「暗くなり始める位置」の割合
    private static func vignette(_ image: CIImage, strength: CGFloat, inner: CGFloat) -> CIImage {
        let extent = image.extent
        let halfDiagonal = hypot(extent.width, extent.height) / 2
        let edge = 1 - strength

        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(x: extent.midX, y: extent.midY)
        gradient.radius0 = Float(halfDiagonal * inner)
        gradient.radius1 = Float(halfDiagonal * 1.05)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
        gradient.color1 = CIColor(red: edge, green: edge, blue: edge)
        guard let shade = gradient.outputImage?.cropped(to: extent) else { return image }

        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = shade
        multiply.backgroundImage = image
        return (multiply.outputImage ?? image).cropped(to: extent)
    }

    /// 色ごとに out = a0 + a1·x + a2·x² + a3·x³ をかける
    private static func polynomial(_ image: CIImage,
                                   r: (CGFloat, CGFloat, CGFloat, CGFloat),
                                   g: (CGFloat, CGFloat, CGFloat, CGFloat),
                                   b: (CGFloat, CGFloat, CGFloat, CGFloat)) -> CIImage {
        let f = CIFilter.colorPolynomial()
        f.inputImage = image
        f.redCoefficients = CIVector(x: r.0, y: r.1, z: r.2, w: r.3)
        f.greenCoefficients = CIVector(x: g.0, y: g.1, z: g.2, w: g.3)
        f.blueCoefficients = CIVector(x: b.0, y: b.1, z: b.2, w: b.3)
        f.alphaCoefficients = CIVector(x: 0, y: 1, z: 0, w: 0)
        return f.outputImage ?? image
    }

    /// ぼかした像をスクリーン合成で薄く重ね、明るい部分をふんわりにじませる。
    /// 元の像はぼかさないので、細部は残る
    /// にじみで甘くなった輪郭を、明るさだけ少し締める（色ノイズは強調しない）
    private static func detail(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = image
        sharpen.sharpness = 0.45
        sharpen.radius = Float(max(1, longSide(extent) / 2000) * 1.2)
        return (sharpen.outputImage ?? image).cropped(to: extent)
    }

    // MARK: - 保存用の拡大

    /// 保存する写真の長い辺の最小値（約2700万画素）。これより小さければ高品質な拡大（Lanczos）で
    /// 大きくする。大きい写真（4800万画素など）は縮めない。拡大したときに細部が残るよう、
    /// カメラが撮った画素はそのまま保存する
    static let savedLongSide: CGFloat = 6048

    /// 写真を保存用の大きさにする。拡大で増えるのは画素数で、写っている情報は増えないため、
    /// 拡大したときは輪郭を軽く締めて見た目の細かさを補う
    static func resizeForSaving(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let long = longSide(extent)
        guard long > 0, long < savedLongSide * 0.95 else { return image }
        let scale = savedLongSide / long
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = image
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1
        guard let up = lanczos.outputImage else { return image }
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = up
        sharpen.sharpness = 0.3
        sharpen.radius = Float(scale * 1.2)
        return (sharpen.outputImage ?? up).cropped(to: up.extent)
    }

    private static func diffusion(_ image: CIImage, radius: CGFloat, amount: CGFloat) -> CIImage {
        let extent = image.extent
        let blurred = image
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: extent)
        let faded = colorMatrix(blurred, r: amount, g: amount, b: amount, bias: (0, 0, 0))
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = faded
        screen.backgroundImage = image
        return (screen.outputImage ?? image).cropped(to: extent)
    }

    private static func toneCurve(_ image: CIImage?, _ p: [(CGFloat, CGFloat)]) -> CIImage {
        let curve = CIFilter.toneCurve()
        curve.inputImage = image
        curve.point0 = CGPoint(x: p[0].0, y: p[0].1)
        curve.point1 = CGPoint(x: p[1].0, y: p[1].1)
        curve.point2 = CGPoint(x: p[2].0, y: p[2].1)
        curve.point3 = CGPoint(x: p[3].0, y: p[3].1)
        curve.point4 = CGPoint(x: p[4].0, y: p[4].1)
        return curve.outputImage ?? image ?? CIImage.empty()
    }

    private static func colorMatrix(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat,
                                    bias: (CGFloat, CGFloat, CGFloat)) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: bias.0, y: bias.1, z: bias.2, w: 0)
        return m.outputImage ?? image
    }

    private static func exposure(_ image: CIImage, ev: Float) -> CIImage {
        let f = CIFilter.exposureAdjust()
        f.inputImage = image
        f.ev = ev
        return f.outputImage ?? image
    }

    /// Core Image は明るさを「光の量に比例する値（リニア）」で計算するため、
    /// 色の調整は見た目どおりの明るさ（sRGB）に変換してから行い、最後に戻す。
    /// リニアのまま黒を持ち上げると、画面全体が白っぽく霞んでしまう
    /// あわせて 0〜1 の範囲に収める。iPhone の写真は色域が広く、
    /// sRGB にすると範囲外（マイナスや 1 超え）の値が出る。そのまま 3 次式や
    /// トーンカーブにかけると値が暴れ、色付きの白い点やまだらになる
    private static func toSRGB(_ image: CIImage) -> CIImage {
        let srgb = image.applyingFilter("CILinearToSRGBToneCurve")
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = srgb
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? srgb
    }

    private static func toLinear(_ image: CIImage) -> CIImage {
        image.applyingFilter("CISRGBToneCurveToLinear")
    }

    private static func longSide(_ r: CGRect) -> CGFloat { max(r.width, r.height) }
    private static func shortSide(_ r: CGRect) -> CGFloat { min(r.width, r.height) }
}
