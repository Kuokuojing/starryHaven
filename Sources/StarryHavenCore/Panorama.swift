import Foundation

public struct PanoramaRequest: Sendable {
    public var frames: [URL] = []
    public var referenceIndex = 0
    public var outputURL: URL?
    public var outputFormat: OutputFormat?
    public init() {}
}

public struct PanoramaResult: Sendable {
    public var image: ImageBuffer
    public var preview: ImageBuffer
    public var log: [String]
    public var frames: Int
    public var canvasSize: (Int, Int)
    public var outputURL: URL?
}

public enum PanoramaError: Error, CustomStringConvertible {
    case noFrames
    case alignment(String)
    public var description: String {
        switch self {
        case .noFrames: return "没有可拼接的帧"
        case .alignment(let s): return "全景对齐失败：\(s)"
        }
    }
}

public enum PanoramaStitcher {
    public static func stitch(frames: [ImageBuffer],
                              referenceIndex: Int,
                              progress: ((Double, String) -> Void)? = nil) throws -> (image: ImageBuffer, log: [String], canvas: (Int, Int)) {
        guard !frames.isEmpty else { throw PanoramaError.noFrames }
        let refIndex = min(max(referenceIndex, 0), frames.count - 1)
        let ref = frames[refIndex]
        var log: [String] = []
        log.append("参考帧 \(refIndex + 1)/\(frames.count)，\(ref.width)×\(ref.height)")
        let refField = StarDetector.detect(image: ref)
        guard refField.stars.count >= 8 else { throw PanoramaError.alignment("参考帧星点不足 (\(refField.stars.count))") }
        let refBg = Calibration.background(ref)
        var transforms: [Matrix3] = []
        transforms.reserveCapacity(frames.count)
        for i in 0..<frames.count {
            if i == refIndex { transforms.append(.identity); continue }
            let field = StarDetector.detect(image: frames[i])
            do {
                let r = try StarRegistration.register(reference: refField, image: field,
                                                      referenceWidth: ref.width, referenceHeight: ref.height,
                                                      imageWidth: frames[i].width, imageHeight: frames[i].height)
                transforms.append(r.transform)
                log.append("帧 \(i + 1)：\(r.message)")
            } catch {
                throw PanoramaError.alignment("帧 \(i + 1)：\(error)")
            }
            progress?(Double(i + 1) / Double(frames.count) * 0.7, "对齐 \(i + 1)/\(frames.count)")
        }

        var minX = 0.0, minY = 0.0
        var maxX = Double(ref.width), maxY = Double(ref.height)
        for (i, t) in transforms.enumerated() {
            let b = Warp.transformedBounds(width: frames[i].width, height: frames[i].height, imageToReference: t)
            minX = min(minX, b.minX); minY = min(minY, b.minY)
            maxX = max(maxX, b.maxX); maxY = max(maxY, b.maxY)
        }
        let canvasW = max(1, Int(ceil(maxX - minX)))
        let canvasH = max(1, Int(ceil(maxY - minY)))
        let offset = Matrix3([1, 0, -minX, 0, 1, -minY, 0, 0, 1])
        var accum = [Double](repeating: 0, count: canvasW * canvasH * 3)
        var weights = [Double](repeating: 0, count: canvasW * canvasH)
        for i in 0..<frames.count {
            var frame = frames[i]
            if i != refIndex { frame = Calibration.normalizeBackground(frame, to: refBg) }
            let h = offset.multiply(transforms[i])
            guard let warped = Warp.warpRegion(frame, imageToReference: h,
                                              region: CGRect(x: 0, y: 0, width: canvasW, height: canvasH),
                                              fullWidth: canvasW, fullHeight: canvasH) else {
                throw PanoramaError.alignment("帧 \(i + 1) 变换失败")
            }
            for p in 0..<(canvasW * canvasH) {
                let w = Double(warped.coverage[p])
                if w <= 0 { continue }
                for c in 0..<3 { accum[p * 3 + c] += Double(warped.image.pixels[p * 3 + c]) * w }
                weights[p] += w
            }
            progress?(0.7 + 0.25 * Double(i + 1) / Double(frames.count), "合成 \(i + 1)/\(frames.count)")
        }
        var out = ImageBuffer(width: canvasW, height: canvasH, channels: 3)
        for p in 0..<(canvasW * canvasH) {
            let w = max(weights[p], 1e-9)
            for c in 0..<3 { out.pixels[p * 3 + c] = Float(accum[p * 3 + c] / w) }
        }
        log.append("画布 \(canvasW)×\(canvasH)")
        return (out, log, (canvasW, canvasH))
    }

    public static func run(_ request: PanoramaRequest,
                           progress: ((Double, String) -> Void)? = nil) throws -> PanoramaResult {
        guard !request.frames.isEmpty else { throw PanoramaError.noFrames }
        var frames: [ImageBuffer] = []
        for (i, url) in request.frames.enumerated() {
            frames.append(try ImageLoader.load(url: url))
            progress?(0.02 + 0.25 * Double(i + 1) / Double(request.frames.count), "读取 \(url.lastPathComponent)")
        }
        let stitched = try stitch(frames: frames, referenceIndex: request.referenceIndex, progress: progress)
        var log = stitched.log
        if let url = request.outputURL {
            try ImageWriter.save(stitched.image, url: url, format: request.outputFormat ?? ImageWriter.format(for: url))
            log.append("已写入 \(url.path)")
        }
        return PanoramaResult(image: stitched.image, preview: PostProcess.stretch(stitched.image),
                              log: log, frames: frames.count, canvasSize: stitched.canvas,
                              outputURL: request.outputURL)
    }
}
