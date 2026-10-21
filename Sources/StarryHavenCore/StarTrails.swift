import Foundation

public enum LandscapeMotion: String, CaseIterable, Sendable {
    case fixed = "固定地景"
    case dynamic = "动态地景"
}

public struct StarTrailRequest: Sendable {
    public var lights: [URL] = []
    public var method: StackMethod = .maximum
    public var landscape: LandscapeMotion = .fixed
    public var compositeLandscape = true
    public var referenceIndex = 0
    public var removeAircraft = false
    public var vignetteCorrection: Double = 0
    public var distortionCorrection: Double = 0
    public var glow: Double = 0
    public var glowRadius: Double = 2
    public var outputURL: URL?
    public var outputFormat: OutputFormat?
    public init() {}
}

public struct StarTrailResult: Sendable {
    public var image: ImageBuffer
    public var preview: ImageBuffer
    public var log: [String]
    public var usedFrames: Int
    public var maskedFrames: Int
    public var outputURL: URL?
}

/// Detects long straight bright lines (aircraft/satellite trails) with a
/// downsampled Hough transform. Stars contribute only one vote per angle and
/// cannot form a peak; a line accumulates votes along its whole length.
public enum AircraftTrail {
    public static func mask(in image: ImageBuffer, sensitivity: Double = 5.0) -> [Float] {
        let factor = 4
        let dw = max(8, image.width / factor)
        let dh = max(8, image.height / factor)
        var small = [Float](repeating: 0, count: dw * dh)
        let lum = image.luminance()
        for y in 0..<dh {
            for x in 0..<dw {
                var s: Float = 0
                var n: Float = 0
                for dy in 0..<factor {
                    let sy = min(y * factor + dy, image.height - 1)
                    for dx in 0..<factor {
                        let sx = min(x * factor + dx, image.width - 1)
                        s += lum[sy * image.width + sx]
                        n += 1
                    }
                }
                small[y * dw + x] = s / n
            }
        }
        // High-pass against a 5x5 box blur.
        let r = 2
        var blurred = [Float](repeating: 0, count: small.count)
        for y in 0..<dh {
            for x in 0..<dw {
                var s: Float = 0
                var n: Float = 0
                for dy in -r...r {
                    let yy = min(max(y + dy, 0), dh - 1)
                    for dx in -r...r {
                        let xx = min(max(x + dx, 0), dw - 1)
                        s += small[yy * dw + xx]
                        n += 1
                    }
                }
                blurred[y * dw + x] = s / n
            }
        }
        var high = [Float](repeating: 0, count: small.count)
        for i in 0..<small.count { high[i] = small[i] - blurred[i] }
        let med = RGBMath.median(high)
        let mad = RGBMath.mad(high, median: med)
        let threshold = Float(Double(med) + sensitivity * max(Double(mad) * 1.4826, 0.002))

        var points: [(Int, Int)] = []
        for y in 0..<dh {
            for x in 0..<dw where high[y * dw + x] > threshold {
                points.append((x, y))
            }
        }
        guard points.count > 20 else { return [Float](repeating: 0, count: image.count) }

        let diag = Int(ceil(hypot(Double(dw), Double(dh))))
        let angleCount = 90
        let rhoCount = diag * 2 + 1
        var cosTable = [Double](repeating: 0, count: angleCount)
        var sinTable = [Double](repeating: 0, count: angleCount)
        for a in 0..<angleCount {
            let theta = Double(a) * Double.pi / Double(angleCount)
            cosTable[a] = cos(theta)
            sinTable[a] = sin(theta)
        }
        var mask = [Float](repeating: 0, count: image.count)
        var remaining = points
        for _ in 0..<2 {
            guard remaining.count > 20 else { break }
            var acc = [Int](repeating: 0, count: angleCount * rhoCount)
            for (x, y) in remaining {
                for a in 0..<angleCount {
                    let rho = Int(round(Double(x) * cosTable[a] + Double(y) * sinTable[a])) + diag
                    if rho >= 0 && rho < rhoCount { acc[a * rhoCount + rho] += 1 }
                }
            }
            guard let best = acc.enumerated().max(by: { $0.element < $1.element }), best.element >= 25 else { break }
            let meanVotes = Double(acc.reduce(0, +)) / Double(acc.count)
            if Double(best.element) < meanVotes * 5 { break }
            let angleIndex = best.offset / rhoCount
            let rhoIndex = best.offset % rhoCount - diag
            // Mask a 4 px band around the line in full-resolution coordinates.
            let ca = cosTable[angleIndex], sa = sinTable[angleIndex]
            let rhoFull = Double(rhoIndex * factor)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let d = abs(Double(x) * ca + Double(y) * sa - rhoFull)
                    if d <= 4 { mask[y * image.width + x] = 1 }
                }
            }
            // Remove the inlier points and look for a second trail.
            var rest: [(Int, Int)] = []
            for (x, y) in remaining {
                let rho = Double(x) * ca + Double(y) * sa
                if abs(rho - Double(rhoIndex)) > 3 { rest.append((x, y)) }
            }
            remaining = rest
        }
        return mask
    }
}

public enum StarTrailPipeline {
    public static func run(_ request: StarTrailRequest,
                           progress: ((Double, String) -> Void)? = nil) throws -> StarTrailResult {
        guard !request.lights.isEmpty else { throw StackPipelineError.noLights }
        var log: [String] = []
        func report(_ p: Double, _ s: String) { log.append(s); progress?(p, s) }
        var frames: [ImageBuffer] = []
        var lens = LensCorrectionOptions()
        lens.vignette = request.vignetteCorrection
        lens.distortion = request.distortionCorrection
        for (i, url) in request.lights.enumerated() {
            var image = try ImageLoader.load(url: url)
            if lens.vignette != 0 || lens.distortion != 0 { image = LensCorrection.apply(image, options: lens) }
            frames.append(image)
            report(0.05 + 0.35 * Double(i + 1) / Double(request.lights.count), "读取 \(url.lastPathComponent)")
        }
        let refIndex = min(max(request.referenceIndex, 0), frames.count - 1)
        let width = frames[refIndex].width, height = frames[refIndex].height

        var transforms = [Matrix3](repeating: .identity, count: frames.count)
        if request.landscape == .dynamic {
            let refField = StarDetector.detect(image: frames[refIndex])
            for i in 0..<frames.count where i != refIndex {
                let field = StarDetector.detect(image: frames[i])
                do {
                    let r = try StarRegistration.register(reference: refField, image: field,
                                                          referenceWidth: width, referenceHeight: height,
                                                          imageWidth: frames[i].width, imageHeight: frames[i].height)
                    transforms[i] = r.transform
                    report(0.4 + 0.25 * Double(i + 1) / Double(frames.count), "\(request.lights[i].lastPathComponent)：\(r.message)")
                } catch {
                    report(0.4 + 0.25 * Double(i + 1) / Double(frames.count), "对齐失败，使用原始帧：\(error)")
                }
            }
        }

        var stackFrames: [StackFrame] = []
        var masked = 0
        for i in 0..<frames.count {
            var mask: [Float]?
            if request.removeAircraft {
                let m = AircraftTrail.mask(in: frames[i])
                if m.contains(where: { $0 > 0.5 }) { masked += 1 }
                mask = m
            }
            stackFrames.append(StackFrame(image: frames[i], transform: transforms[i], mask: mask))
        }
        var options = StackOptions()
        options.method = request.method
        options.bandHeight = 128
        let stack = try Stacker.stack(frames: stackFrames, fullWidth: width, fullHeight: height, options: options) { p in
            progress?(0.7 + 0.2 * p, String(format: "合成星轨 %.0f%%", p * 100))
        }
        var output = stack.image
        if request.landscape == .dynamic && request.compositeLandscape {
            report(0.94, "天地分离合成地景…")
            if let mask = try? SkySegmenter.segment(image: PostProcess.stretch(frames[refIndex])) {
                for y in 0..<height {
                    for x in 0..<width where mask.value(x: x, y: y) < 0.5 {
                        for c in 0..<3 { output[x, y, c] = frames[refIndex][x, y, c] }
                    }
                }
            }
        }
        if request.glow > 0 {
            output = PostProcess.starTrailGlow(output, amount: request.glow, radius: request.glowRadius)
            report(0.97, "星轨辉光")
        }
        if let url = request.outputURL {
            try ImageWriter.save(output, url: url, format: request.outputFormat ?? ImageWriter.format(for: url))
            report(0.99, "已写入 \(url.path)")
        }
        report(1.0, "完成：\(frames.count) 帧")
        return StarTrailResult(image: output, preview: PostProcess.stretch(output), log: log,
                               usedFrames: frames.count, maskedFrames: masked, outputURL: request.outputURL)
    }
}
