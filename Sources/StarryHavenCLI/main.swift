import Foundation
import StarryHavenCore

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func parseArgs(_ args: [String]) -> (positional: [String], options: [String: [String]]) {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                options[key, default: []].append(args[i + 1])
                i += 2
            } else {
                options[key, default: []].append("true")
                i += 1
            }
        } else {
            positional.append(a)
            i += 1
        }
    }
    return (positional, options)
}

func method(from name: String) -> StackMethod {
    switch name.lowercased() {
    case "mean", "均值": return .mean
    case "median", "中值": return .median
    case "min", "minimum", "最小值": return .minimum
    case "max", "maximum", "最大值": return .maximum
    default: return .sigmaClipped
    }
}

func maskImage(_ mask: SkyMask) -> ImageBuffer {
    var img = ImageBuffer(width: mask.width, height: mask.height, channels: 3)
    for i in 0..<mask.mask.count {
        let v = mask.mask[i]
        img.pixels[i * 3] = v; img.pixels[i * 3 + 1] = v; img.pixels[i * 3 + 2] = v
    }
    return img
}

func imagesIn(_ path: String) -> [URL] {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    return files.filter { ["tif", "tiff", "fit", "fits", "png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func savePreview(_ image: ImageBuffer, path: String?) {
    guard let path = path else { return }
    try? ImageWriter.saveDisplay(image, url: URL(fileURLWithPath: path), format: ImageWriter.format(for: URL(fileURLWithPath: path)))
    print("preview: \(path)")
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("""
    starryhaven-cli — 星空难民营 处理核心

    用法:
      starryhaven-cli models [--describe]
      starryhaven-cli skyseg <输入> <输出.png> [--manual]
      starryhaven-cli starnet <输入> <starless输出> [--stars <路径>] [--recompose <路径>] [--amount 1.0] [--stride 256]
      starryhaven-cli denoise <输入> <输出> [--stride 256]
      starryhaven-cli stack --light <文件> [--light ...] [--bias ...] [--dark ...] [--flat ...]
                         --output <文件> [--method sigma|mean|median|min|max]
                         [--sigma-low 4] [--sigma-high 5] [--reference 0]
                         [--scene full|skyland] [--manual-mask <路径>] [--crop] [--badpixel]
                         [--no-bg-normalize] [--stretch-output]
      starryhaven-cli selftest --out <目录>
    """)
    exit(0)
}
let rest = Array(args.dropFirst())
let (positional, options) = parseArgs(rest)

switch command {
case "models":
    print(ModelLocator.statusDescription)
    if options["describe"] != nil {
        print(StarNetInfo.describe())
        print(DeepSNR.describe())
        print(SkySegmenter.describeModel())
    }

case "skyseg":
    guard positional.count >= 2 else { fail("skyseg 需要输入与输出路径") }
    let input = try ImageLoader.loadDisplayReferred(url: URL(fileURLWithPath: positional[0]))
    let mask: SkyMask
    if options["manual"] != nil {
        mask = SkyComposite.manualMask(image: input)
    } else {
        mask = try SkySegmenter.segment(image: input)
    }
    try ImageWriter.save(maskImage(mask), url: URL(fileURLWithPath: positional[1]), format: ImageWriter.format(for: URL(fileURLWithPath: positional[1])))
    print("SkySeg mask written: \(positional[1]) (\(mask.width)x\(mask.height))")

case "starnet":
    guard positional.count >= 2 else { fail("starnet 需要输入与输出路径") }
    let input = try ImageLoader.loadDisplayReferred(url: URL(fileURLWithPath: positional[0]))
    let stride = Int(options["stride"]?.first ?? "256") ?? 256
    let result = try StarSeparation.separate(image: input, stride: stride) { p in
        FileHandle.standardError.write(String(format: "\rStarNet2 %.0f%%", p * 100).data(using: .utf8)!)
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    try ImageWriter.saveDisplay(result.starless, url: URL(fileURLWithPath: positional[1]), format: ImageWriter.format(for: URL(fileURLWithPath: positional[1])))
    if let starsPath = options["stars"]?.first {
        try ImageWriter.saveDisplay(result.stars, url: URL(fileURLWithPath: starsPath), format: ImageWriter.format(for: URL(fileURLWithPath: starsPath)))
    }
    if let recomposePath = options["recompose"]?.first {
        let amount = Double(options["amount"]?.first ?? "1.0") ?? 1.0
        let rec = StarSeparation.recompose(starless: result.starless, stars: result.stars, amount: amount)
        try ImageWriter.saveDisplay(rec, url: URL(fileURLWithPath: recomposePath), format: ImageWriter.format(for: URL(fileURLWithPath: recomposePath)))
    }
    print("StarNet2 done: \(result.backend), output \(positional[1])")

case "denoise":
    guard positional.count >= 2 else { fail("denoise 需要输入与输出路径") }
    let input = try ImageLoader.loadDisplayReferred(url: URL(fileURLWithPath: positional[0]))
    let stride = Int(options["stride"]?.first ?? "256") ?? 256
    let out = try DeepSNR.denoise(image: input, stride: stride)
    try ImageWriter.saveDisplay(out, url: URL(fileURLWithPath: positional[1]), format: ImageWriter.format(for: URL(fileURLWithPath: positional[1])))
    print("DeepSNR done: \(positional[1]) · \(ModelLocator.artifactDescription(ModelLocator.deepSNR))")

case "trails":
    guard let dir = options["input"]?.first, let output = options["output"]?.first else {
        fail("trails 需要 --input <帧目录> --output <文件>")
    }
    var req = StarTrailRequest()
    req.lights = imagesIn(dir)
    guard !req.lights.isEmpty else { fail("目录中没有图像帧") }
    req.method = method(from: options["method"]?.first ?? "max")
    req.landscape = (options["landscape"]?.first ?? "fixed") == "dynamic" ? .dynamic : .fixed
    req.removeAircraft = options["remove-aircraft"] != nil
    req.glow = Double(options["glow"]?.first ?? "0") ?? 0
    req.glowRadius = Double(options["glow-radius"]?.first ?? "2") ?? 2
    req.outputURL = URL(fileURLWithPath: output)
    let result = try StarTrailPipeline.run(req) { p, m in
        FileHandle.standardError.write(String(format: "\r[%3.0f%%] %@", p * 100, m).data(using: .utf8)!)
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    for line in result.log { print(line) }
    print("trails: frames=\(result.usedFrames) maskedFrames=\(result.maskedFrames) size=\(result.image.width)x\(result.image.height) output=\(output)")
    savePreview(result.preview, path: options["preview"]?.first)

case "timelapse":
    guard let dir = options["input"]?.first, let output = options["output"]?.first else {
        fail("timelapse 需要 --input <帧目录> --output <视频.mp4>")
    }
    var req = TimelapseRequest()
    req.frames = imagesIn(dir)
    guard !req.frames.isEmpty else { fail("目录中没有图像帧") }
    req.deflickerWindow = Int(options["deflicker"]?.first ?? "15") ?? 15
    req.fps = Int32(options["fps"]?.first ?? "24") ?? 24
    req.outputVideoURL = URL(fileURLWithPath: output)
    if let kd = options["keyframes"]?.first {
        req.keyframeDirectory = URL(fileURLWithPath: kd)
        req.keyframeEvery = max(1, req.frames.count / 10)
    }
    let result = try TimelapseProcessor.run(req) { p, m in
        FileHandle.standardError.write(String(format: "\r[%3.0f%%] %@", p * 100, m).data(using: .utf8)!)
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    for line in result.log { print(line) }
    print(String(format: "timelapse: frames=%d flicker=%.4f->%.4f videoBytes=%d duration=%.2fs output=%@",
                 result.frameCount, result.flickerBefore, result.flickerAfter, result.videoBytes, result.videoDuration, output))

case "pano":
    guard let dir = options["input"]?.first, let output = options["output"]?.first else {
        fail("pano 需要 --input <帧目录> --output <文件>")
    }
    var req = PanoramaRequest()
    req.frames = imagesIn(dir)
    guard !req.frames.isEmpty else { fail("目录中没有图像帧") }
    req.referenceIndex = Int(options["reference"]?.first ?? "0") ?? 0
    req.outputURL = URL(fileURLWithPath: output)
    let result = try PanoramaStitcher.run(req)
    for line in result.log { print(line) }
    print("pano: frames=\(result.frames) canvas=\(result.canvasSize.0)x\(result.canvasSize.1) output=\(output)")
    savePreview(result.preview, path: options["preview"]?.first)

case "narrowband":
    guard let ha = options["ha"]?.first, let oiii = options["oiii"]?.first, let output = options["output"]?.first else {
        fail("narrowband 需要 --ha <文件> --oiii <文件> --output <文件>")
    }
    var req = NarrowbandRequest()
    req.ha = URL(fileURLWithPath: ha)
    req.oiii = URL(fileURLWithPath: oiii)
    req.sii = options["sii"]?.first.map { URL(fileURLWithPath: $0) }
    let palette = (options["palette"]?.first ?? "sho").lowercased()
    req.palette = palette == "hoo" ? .hoo : (palette == "hso" ? .hso : .sho)
    req.applyStretch = options["no-stretch"] == nil
    req.removeStars = options["remove-stars"] != nil
    req.outputURL = URL(fileURLWithPath: output)
    let result = try NarrowbandComposer.run(req)
    for line in result.log { print(line) }
    print(String(format: "narrowband: palette=%@ size=%dx%d meanR=%.4f meanG=%.4f meanB=%.4f output=%@",
                 req.palette.rawValue, result.image.width, result.image.height,
                 result.image.channel(0).reduce(0, +) / Float(result.image.count),
                 result.image.channel(1).reduce(0, +) / Float(result.image.count),
                 result.image.channel(2).reduce(0, +) / Float(result.image.count), output))

case "lens":
    guard let input = options["input"]?.first, let output = options["output"]?.first else {
        fail("lens 需要 --input <图像> --output <图像>")
    }
    var meta = ImageMetadata.read(url: URL(fileURLWithPath: input))
    if let v = options["make"]?.first { meta.make = v }
    if let v = options["model"]?.first { meta.model = v }
    if let v = options["lens-model"]?.first { meta.lensModel = v }
    if let v = options["focal"]?.first { meta.focalLength = Double(v) }
    if let v = options["aperture"]?.first { meta.aperture = Double(v) }
    var mode: LensProfileMode = .none
    if let lcp = options["lcp"]?.first { mode = .adobeLCP(URL(fileURLWithPath: lcp)) }
    else if options["auto"] != nil { mode = .automatic }
    let image = try ImageLoader.loadDisplayReferred(url: URL(fileURLWithPath: input))
    let calibration = LensProfileCorrection.calibration(for: mode, metadata: meta)
    var corrected = image
    if let c = calibration { corrected = LensProfileCorrection.apply(c, to: image) }
    var manual = LensCorrectionOptions()
    manual.vignette = Double(options["vignette"]?.first ?? "0") ?? 0
    manual.distortion = Double(options["distortion"]?.first ?? "0") ?? 0
    if manual.vignette != 0 || manual.distortion != 0 { corrected = LensCorrection.apply(corrected, options: manual) }
    func ratio(_ img: ImageBuffer) -> Double {
        let c = Double(img[img.width / 2, img.height / 2, 0])
        let corner = Double(img[3, 3, 0])
        return c > 1e-9 ? corner / c : 0
    }
    print("metadata: \(meta.summary)")
    print("calibration: \(calibration?.source ?? "none")")
    print(String(format: "lens: corner/center %.4f -> %.4f", ratio(image), ratio(corrected)))
    try ImageWriter.saveDisplay(corrected, url: URL(fileURLWithPath: output), format: ImageWriter.format(for: URL(fileURLWithPath: output)))
    if let before = options["preview-before"]?.first {
        try ImageWriter.saveDisplay(image, url: URL(fileURLWithPath: before), format: ImageWriter.format(for: URL(fileURLWithPath: before)))
    }
    print("output: \(output)")

case "enhance":
    guard let input = options["input"]?.first, let output = options["output"]?.first else {
        fail("enhance 需要 --input <图像> --output <图像>")
    }
    let image = try ImageLoader.loadDisplayReferred(url: URL(fileURLWithPath: input))
    var e = EnhancementOptions()
    e.localContrast = Double(options["local-contrast"]?.first ?? "0.35") ?? 0.35
    e.structure = Double(options["structure"]?.first ?? "0.25") ?? 0.25
    e.structureRadius = Double(options["structure-radius"]?.first ?? "30") ?? 30
    e.skylight = Double(options["skylight"]?.first ?? "0") ?? 0
    e.glow = Double(options["glow"]?.first ?? "0") ?? 0
    e.glowRadius = Double(options["glow-radius"]?.first ?? "2") ?? 2
    var mask: SkyMask?
    if options["sky-only"] != nil { mask = try SkySegmenter.segment(image: image) }
    let out = PostProcess.enhance(image, options: e, mask: mask)
    func hp(_ img: ImageBuffer) -> Double {
        let blur = PostProcess.gaussianBlur(img, sigma: 2)
        var s = 0.0
        for i in 0..<img.count { let d = Double(img.pixels[i * 3] - blur.pixels[i * 3]); s += d * d }
        return sqrt(s / Double(img.count))
    }
    print(String(format: "enhance: highPass %.5f -> %.5f size=%dx%d skyOnly=%@",
                 hp(image), hp(out), out.width, out.height, mask == nil ? "no" : "yes"))
    try ImageWriter.saveDisplay(out, url: URL(fileURLWithPath: output), format: ImageWriter.format(for: URL(fileURLWithPath: output)))
    if let before = options["preview-before"]?.first {
        try ImageWriter.saveDisplay(image, url: URL(fileURLWithPath: before), format: ImageWriter.format(for: URL(fileURLWithPath: before)))
    }
    print("output: \(output)")

case "stack":
    guard let outputPath = options["output"]?.first else { fail("stack 需要 --output") }
    var request = StackRequest()
    request.lights = (options["light"] ?? []).map { URL(fileURLWithPath: $0) }
    request.biasFrames = (options["bias"] ?? []).map { URL(fileURLWithPath: $0) }
    request.darkFrames = (options["dark"] ?? []).map { URL(fileURLWithPath: $0) }
    request.flatFrames = (options["flat"] ?? []).map { URL(fileURLWithPath: $0) }
    request.referenceIndex = Int(options["reference"]?.first ?? "0") ?? 0
    request.method = method(from: options["method"]?.first ?? "sigma")
    request.lowSigma = Double(options["sigma-low"]?.first ?? "4") ?? 4
    request.highSigma = Double(options["sigma-high"]?.first ?? "5") ?? 5
    request.sceneMode = (options["scene"]?.first ?? "full") == "skyland" ? .skyLand : .fullFrame
    request.manualMaskURL = options["manual-mask"]?.first.map { URL(fileURLWithPath: $0) }
    request.cropToOverlap = options["crop"] != nil
    request.badPixelCorrection = options["badpixel"] != nil
    request.normalizeBackground = options["no-bg-normalize"] == nil
    request.stretchOutput = options["stretch-output"] != nil
    request.outputURL = URL(fileURLWithPath: outputPath)
    let result = try StackPipeline.run(request) { p, msg in
        FileHandle.standardError.write(String(format: "\r[%3.0f%%] %@", p * 100, msg).data(using: .utf8)!)
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    for line in result.log { print(line) }
    if let url = result.outputURL { print("saved: \(url.path)") }

case "inspect":
    guard let path = positional.first else { fail("inspect 需要图片路径") }
    let img = options["display"] != nil ? try ImageLoader.loadDisplayReferred(url: URL(fileURLWithPath: path)) : try ImageLoader.load(url: URL(fileURLWithPath: path))
    let s = img.statistics()
    print(String(format: "size %dx%d min %.6f max %.6f mean %.6f", img.width, img.height, s.min, s.max, s.mean))
    for (x, y) in [(10, 10), (256, 256), (500, 500)] where x < img.width && y < img.height {
        print(String(format: "pixel(%d,%d) = %.6f %.6f %.6f", x, y, img[x, y, 0], img[x, y, 1], img[x, y, 2]))
    }
    let st = PostProcess.stretch(img)
    let ss = st.statistics()
    print(String(format: "stretched min %.6f max %.6f mean %.6f", ss.min, ss.max, ss.mean))

case "detect":
    guard let path = positional.first else { fail("detect 需要图片路径") }
    let img = options["display"] != nil ? try ImageLoader.loadDisplayReferred(url: URL(fileURLWithPath: path)) : try ImageLoader.load(url: URL(fileURLWithPath: path))
    let threshold = Double(options["sigma"]?.first ?? "5") ?? 5
    var opts = DetectionOptions(); opts.thresholdSigma = threshold
    let field = StarDetector.detect(image: img, options: opts)
    let fwhm = field.stars.map { $0.fwhm }.sorted()
    print(String(format: "%@: %d stars, background %.5f, noise %.5f, median FWHM %.3f",
                 path, field.stars.count, field.background, field.noise,
                 fwhm.isEmpty ? 0 : fwhm[fwhm.count/2]))

case "thumb":
    guard positional.count >= 2 else { fail("thumb 需要输入与输出") }
    let img = try ImageLoader.load(url: URL(fileURLWithPath: positional[0]))
    let maxDim = Int(options["size"]?.first ?? "900") ?? 900
    let scale = min(1.0, Double(maxDim) / Double(max(img.width, img.height)))
    let small = img.resized(toWidth: max(1, Int(Double(img.width) * scale)), toHeight: max(1, Int(Double(img.height) * scale)))
    let shown = PostProcess.stretch(small)
    try ImageWriter.saveDisplay(shown, url: URL(fileURLWithPath: positional[1]), format: ImageWriter.format(for: URL(fileURLWithPath: positional[1])))
    print("thumb \(small.width)x\(small.height)")

case "dumpchw":
    guard positional.count >= 2 else { fail("dumpchw 需要输入与输出") }
    let img = try ImageLoader.loadDisplayReferred(url: URL(fileURLWithPath: positional[0])).resized(toWidth: 320, toHeight: 320)
    var data = [Float](repeating: 0, count: 3*320*320)
    for c in 0..<3 { for y in 0..<320 { for x in 0..<320 { data[c*320*320 + y*320 + x] = img[x,y,c] } } }
    let d = data.withUnsafeBufferPointer { Data(buffer: $0) }
    try d.write(to: URL(fileURLWithPath: positional[1]))
    print("wrote CHW 3x320x320")

case "gen":
    guard let out = options["out"]?.first else { fail("gen 需要 --out") }
    let w = Int(options["width"]?.first ?? "512") ?? 512
    let h = Int(options["height"]?.first ?? "512") ?? 512
    let count = Int(options["count"]?.first ?? "60") ?? 60
    let seed = UInt64(options["seed"]?.first ?? "42") ?? 42
    let noise = Double(options["noise"]?.first ?? "0.004") ?? 0.004
    var image: ImageBuffer
    if let horizon = options["horizon"]?.first.flatMap({ Int($0) }) {
        image = SyntheticScene.horizonScene(width: w, height: h, horizonY: horizon, seed: seed).image
    } else {
        let stars = SyntheticScene.randomStars(width: w, height: h, count: count, seed: seed, minSeparation: 10)
        let bg = Double(options["background"]?.first ?? "0.02") ?? 0.02
        image = SyntheticScene.starField(width: w, height: h, stars: stars, background: bg, backgroundGradient: 0.0,
                                         noise: noise, seed: seed + 1)
        if options["nebula"] != nil {
            SyntheticScene.addNebula(to: &image, center: (Double(w) * 0.55, Double(h) * 0.5), radius: Double(min(w, h)) * 0.2, brightness: 0.05)
        }
    }
    let fmt = ImageWriter.format(for: URL(fileURLWithPath: out))
    if let vs = options["vignette"]?.first, let strength = Double(vs) {
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        let maxR2 = cx * cx + cy * cy
        for y in 0..<h {
            for x in 0..<w {
                let r2 = (pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)) / max(maxR2, 1)
                let gain = Float(1 - strength * r2)
                for c in 0..<3 { image[x, y, c] = max(0, image[x, y, c] * gain) }
            }
        }
    }
    if options["stretch"] != nil {
        image = PostProcess.stretch(image)
        try ImageWriter.saveDisplay(image, url: URL(fileURLWithPath: out), format: fmt)
    } else {
        try ImageWriter.save(image, url: URL(fileURLWithPath: out), format: fmt)
    }
    print("wrote \(out) \(w)x\(h)")

case "demo-sequence":
    guard let dirPath = options["out"]?.first, let kind = options["kind"]?.first else {
        fail("demo-sequence 需要 --out <目录> --kind trails|timelapse|pano|narrowband")
    }
    let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    switch kind {
    case "trails":
        for i in 0..<20 {
            var img = ImageBuffer(width: 320, height: 200, channels: 3)
            for y in 0..<200 { for x in 0..<320 {
                let g = 0.03 + 0.02 * Double((x / 13) % 3) + 0.01 * sin(Double(y) * 0.2)
                for c in 0..<3 { img[x, y, c] = Float(g) }
            } }
            SyntheticScene.addStar(to: &img, .init(x: 40 + Double(i) * 4, y: 100, peak: 0.95, sigma: 1.6))
            try ImageWriter.save(img, url: dir.appendingPathComponent(String(format: "trail-%02d.tif", i)), format: .tiff16)
        }
    case "timelapse":
        let gains: [Float] = [0.6, 1.4, 0.75, 1.25, 0.8, 1.2, 0.9, 1.1, 0.7, 1.3, 0.85, 1.15]
        for (i, g) in gains.enumerated() {
            var img = ImageBuffer(width: 320, height: 200, channels: 3)
            for y in 0..<200 { for x in 0..<320 {
                for c in 0..<3 { img[x, y, c] = Float(0.08 + 0.03 * sin(Double(x) * 0.05)) * g }
            } }
            SyntheticScene.addStar(to: &img, .init(x: 60 + Double(i) * 10, y: 60, peak: 0.8 * Double(g), sigma: 1.5))
            try ImageWriter.save(img, url: dir.appendingPathComponent(String(format: "tl-%02d.tif", i)), format: .tiff16)
        }
    case "pano":
        let base = SyntheticScene.starField(width: 600, height: 300,
                                            stars: SyntheticScene.randomStars(width: 600, height: 300, count: 70, seed: 501, minSeparation: 14),
                                            noise: 0.001, seed: 7)
        try ImageWriter.save(base.cropped(x: 0, y: 0, width: 400, height: 300), url: dir.appendingPathComponent("pano-left.tif"), format: .tiff16)
        try ImageWriter.save(base.cropped(x: 200, y: 0, width: 400, height: 300), url: dir.appendingPathComponent("pano-right.tif"), format: .tiff16)
    case "narrowband":
        let channels: [(String, Float, Double, Double)] = [("ha", 0.30, 45, 50), ("oiii", 0.10, 82, 82), ("sii", 0.60, 64, 105)]
        for (name, base, cx, cy) in channels {
            var img = ImageBuffer(width: 128, height: 128, channels: 3)
            for y in 0..<128 { for x in 0..<128 {
                let v = base + 1.2 * base * Float(exp(-pow(Double(x) - cx, 2) / 500 - pow(Double(y) - cy, 2) / 500))
                for c in 0..<3 { img[x, y, c] = v }
            } }
            try ImageWriter.save(img, url: dir.appendingPathComponent("\(name).tif"), format: .tiff16)
        }
    default:
        fail("未知演示序列类型 \(kind)")
    }
    print("demo sequence written to \(dir.path)")

case "meta":
    guard let path = positional.first else { fail("meta 需要图片路径") }
    let meta = ImageMetadata.read(url: URL(fileURLWithPath: path))
    print("metadata: \(meta.summary)")
    print("lens: \(meta.lensModel ?? "nil") focal: \(meta.focalLength ?? 0) aperture: \(meta.aperture ?? 0)")
    if let c = LensfunDatabase.shared.autoCalibration(metadata: meta) {
        print("lensfun: \(c.source) distortion=\(c.distortion != nil) vignette=\(c.vignetting != nil)")
    } else if let c = BundledAdobeLCP.find(metadata: meta) {
        print("adobe LCP: \(c.source)")
    } else {
        print("no automatic profile")
    }

case "selftest":
    let outDir = options["out"]?.first ?? FileManager.default.currentDirectoryPath + "/selftest-output"
    let ok = try SelfTest.run(outputDirectory: URL(fileURLWithPath: outDir, isDirectory: true))
    exit(ok ? 0 : 1)

default:
    fail("未知命令: \(command)")
}
