import Foundation

public enum StackMode: String, CaseIterable, Sendable {
    case normal = "普通模式"
    case professional = "专业模式"
    case deepSky = "深空"
}

public enum SceneMode: String, CaseIterable, Sendable {
    case fullFrame = "全图堆栈"
    case skyLand = "天地分离堆栈"
}

public struct StackRequest: Sendable {
    public var lights: [URL] = []
    public var biasFrames: [URL] = []
    public var darkFrames: [URL] = []
    public var flatFrames: [URL] = []
    public var referenceIndex: Int = 0
    public var mode: StackMode = .normal
    public var method: StackMethod = .sigmaClipped
    public var lowSigma: Double = 4
    public var highSigma: Double = 5
    public var sceneMode: SceneMode = .fullFrame
    public var manualMaskURL: URL?
    public var cropToOverlap = false
    public var badPixelCorrection = false
    public var normalizeBackground = true
    public var vignetteCorrection: Double = 0
    public var distortionCorrection: Double = 0
    public var lensProfileMode: LensProfileMode = .none
    public var lensFocalOverride: Double? = nil
    public var outputURL: URL?
    public var outputFormat: OutputFormat?
    public var stretchOutput = false

    public init() {}
}

public struct StackPipelineResult: Sendable {
    public var image: ImageBuffer
    public var preview: ImageBuffer
    public var coverage: [Float]
    public var cropRect: CGRect
    public var log: [String]
    public var usedFrames: Int
    public var registration: [String: RegistrationResult]
    public var outputURL: URL?
    public var sceneMask: SkyMask?
    public var modelInfo: String
}

public enum StackPipelineError: Error, CustomStringConvertible {
    case noLights
    case calibrationSizeMismatch
    case noUsableFrames(String)
    case referenceUnusable(String)
    public var description: String {
        switch self {
        case .noLights: return "没有导入亮场"
        case .calibrationSizeMismatch: return "校准帧尺寸与亮场不一致"
        case .noUsableFrames(let s): return "没有可用帧：\(s)"
        case .referenceUnusable(let s): return "参考帧不可用：\(s)"
        }
    }
}

public enum StackPipeline {
    public static func run(_ request: StackRequest,
                           files: [URL]? = nil,
                           progress: ((Double, String) -> Void)? = nil) throws -> StackPipelineResult {
        let lightURLs = files ?? request.lights
        guard !lightURLs.isEmpty else { throw StackPipelineError.noLights }
        var log: [String] = []

        func report(_ p: Double, _ s: String) {
            log.append(s)
            progress?(p, s)
        }

        report(0.02, "读取亮场…")
        var lights: [ImageBuffer] = []
        for (i, url) in lightURLs.enumerated() {
            lights.append(try ImageLoader.load(url: url))
            progress?(0.02 + 0.15 * Double(i + 1) / Double(lightURLs.count), "读取 \(url.lastPathComponent)")
        }
        let refIndex = min(max(request.referenceIndex, 0), lights.count - 1)
        let width = lights[refIndex].width
        let height = lights[refIndex].height

        // Calibration masters
        var masters = CalibrationMasters()
        if !request.biasFrames.isEmpty {
            report(0.18, "生成偏置主帧 (\(request.biasFrames.count))")
            let frames = try request.biasFrames.map { try ImageLoader.load(url: $0) }
            masters.bias = Calibration.master(frames: frames)
        }
        if !request.darkFrames.isEmpty {
            report(0.22, "生成暗场主帧 (\(request.darkFrames.count))")
            let frames = try request.darkFrames.map { try ImageLoader.load(url: $0) }
            masters.dark = Calibration.master(frames: frames, subtract: masters.bias)
        }
        if !request.flatFrames.isEmpty {
            report(0.26, "生成平场主帧 (\(request.flatFrames.count))")
            let frames = try request.flatFrames.map { try ImageLoader.load(url: $0) }
            masters.flat = Calibration.flatMaster(frames: frames, bias: masters.bias, dark: masters.dark)
        }
        if request.badPixelCorrection, let d = masters.dark, let f = masters.flat {
            masters.badPixels = Calibration.badPixelMask(dark: d, flat: f)
            let count = masters.badPixels?.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) } ?? 0
            report(0.28, "坏点校正：\(count) 个坏点")
        }
        if let m = masters.bias, m.width != width || m.height != height { throw StackPipelineError.calibrationSizeMismatch }
        if let m = masters.dark, m.width != width || m.height != height { throw StackPipelineError.calibrationSizeMismatch }
        if let m = masters.flat, m.width != width || m.height != height { throw StackPipelineError.calibrationSizeMismatch }

        if case .none = request.lensProfileMode {
        } else {
            for i in 0..<lights.count {
                var metadata = ImageMetadata.read(url: lightURLs[i])
                if let f = request.lensFocalOverride { metadata.focalLength = f }
                if let calibration = LensProfileCorrection.calibration(for: request.lensProfileMode, metadata: metadata) {
                    lights[i] = LensProfileCorrection.apply(calibration, to: lights[i])
                    report(0.29, "镜头校正：\(calibration.source)")
                } else if i == 0 {
                    report(0.29, "镜头配置未匹配（\(metadata.summary)）")
                }
            }
        }

        var options = CalibrationOptions()
        options.badPixelCorrection = request.badPixelCorrection
        var calibrated: [ImageBuffer] = []
        var lensOptions = LensCorrectionOptions()
        lensOptions.vignette = request.vignetteCorrection
        lensOptions.distortion = request.distortionCorrection
        for (i, light) in lights.enumerated() {
            var frame = light
            if lensOptions.vignette != 0 || lensOptions.distortion != 0 {
                frame = LensCorrection.apply(frame, options: lensOptions)
            }
            frame = Calibration.calibrate(light: frame, masters: masters, options: options)
            calibrated.append(frame)
            progress?(0.3 + 0.15 * Double(i + 1) / Double(lights.count), "校准 \(lightURLs[i].lastPathComponent)")
        }

        // Background normalization to the reference frame.
        if request.normalizeBackground {
            let refBg = Calibration.background(calibrated[refIndex])
            for i in 0..<calibrated.count {
                if i == refIndex { continue }
                calibrated[i] = Calibration.normalizeBackground(calibrated[i], to: refBg)
            }
        }

        // Registration.
        report(0.46, "检测星点并计算对齐…")
        let refField = StarDetector.detect(image: calibrated[refIndex])
        var frames: [StackFrame] = []
        var registrationLog: [String: RegistrationResult] = [:]
        var skipped: [String] = []
        var usable: [(index: Int, image: ImageBuffer, transform: Matrix3)] = []
        for i in 0..<calibrated.count {
            if i == refIndex {
                usable.append((i, calibrated[i], .identity))
                continue
            }
            let field = StarDetector.detect(image: calibrated[i])
            do {
                let result = try StarRegistration.register(reference: refField, image: field,
                                                           referenceWidth: width, referenceHeight: height,
                                                           imageWidth: calibrated[i].width, imageHeight: calibrated[i].height)
                registrationLog[lightURLs[i].lastPathComponent] = result
                report(0.46 + 0.25 * Double(i + 1) / Double(calibrated.count),
                       "\(lightURLs[i].lastPathComponent)：\(result.message)")
                usable.append((i, calibrated[i], result.transform))
            } catch {
                skipped.append("\(lightURLs[i].lastPathComponent): \(error)")
                report(0.46 + 0.25 * Double(i + 1) / Double(calibrated.count),
                       "跳过 \(lightURLs[i].lastPathComponent)：\(error)")
            }
        }
        if usable.isEmpty { throw StackPipelineError.noUsableFrames(skipped.joined(separator: "; ")) }
        for u in usable { frames.append(StackFrame(image: u.image, transform: u.transform)) }
        report(0.72, "对齐完成：\(frames.count) 帧可用，\(skipped.count) 帧跳过")

        var stackOptions = StackOptions()
        stackOptions.method = request.method
        stackOptions.lowSigma = request.lowSigma
        stackOptions.highSigma = request.highSigma
        stackOptions.cropToOverlap = request.cropToOverlap
        let stack = try Stacker.stack(frames: frames, fullWidth: width, fullHeight: height, options: stackOptions) { p in
            progress?(0.72 + 0.18 * p, String(format: "堆栈中 %.0f%%", p * 100))
        }
        var output = stack.image

        // Sky/land separation: ground comes from the reference frame, sky from the stack.
        var mask: SkyMask?
        var modelInfo = ""
        if request.sceneMode == .skyLand {
            report(0.92, "计算天地分离蒙版…")
            let stretchedRef = PostProcess.stretch(calibrated[refIndex])
            if let manualURL = request.manualMaskURL {
                let maskImage = try ImageLoader.load(url: manualURL)
                let base = SkyComposite.manualMask(image: maskImage)
                mask = base.upsampled(toWidth: width, toHeight: height)
                modelInfo = "Manual mask: \(manualURL.lastPathComponent)"
            } else {
                mask = try SkySegmenter.segment(image: stretchedRef)
                modelInfo = "SkySeg ONNX · 320×320"
            }
            if let m = mask {
                let cropOrigin = stack.cropRect
                let refCropped: ImageBuffer
                if request.cropToOverlap {
                    refCropped = calibrated[refIndex].cropped(x: Int(cropOrigin.minX), y: Int(cropOrigin.minY),
                                                              width: Int(cropOrigin.width), height: Int(cropOrigin.height))
                } else {
                    refCropped = calibrated[refIndex]
                }
                let maskCropped: SkyMask
                if request.cropToOverlap {
                    var mc = [Float](repeating: 0, count: Int(cropOrigin.width) * Int(cropOrigin.height))
                    for y in 0..<Int(cropOrigin.height) {
                        for x in 0..<Int(cropOrigin.width) {
                            mc[y * Int(cropOrigin.width) + x] = m.value(x: x + Int(cropOrigin.minX), y: y + Int(cropOrigin.minY))
                        }
                    }
                    maskCropped = SkyMask(mask: mc, width: Int(cropOrigin.width), height: Int(cropOrigin.height))
                } else {
                    maskCropped = m
                }
                var composited = output
                for y in 0..<composited.height {
                    for x in 0..<composited.width {
                        let a = maskCropped.value(x: x, y: y)
                        if a < 0.5 {
                            for c in 0..<3 { composited[x, y, c] = refCropped[x, y, c] }
                        }
                    }
                }
                output = composited
            }
        }

        if request.stretchOutput {
            output = PostProcess.stretch(output)
        }
        let preview = PostProcess.stretch(output)

        var outputURL: URL?
        if let url = request.outputURL {
            let format = request.outputFormat ?? ImageWriter.format(for: url)
            try ImageWriter.save(output, url: url, format: format)
            outputURL = url
            report(0.99, "已写入 \(url.path)")
        }
        report(1.0, "完成：\(frames.count) 帧，\(output.width)×\(output.height)")
        return StackPipelineResult(image: output, preview: preview, coverage: stack.coverage,
                                   cropRect: stack.cropRect, log: log, usedFrames: frames.count,
                                   registration: registrationLog, outputURL: outputURL,
                                   sceneMask: mask, modelInfo: modelInfo)
    }
}
