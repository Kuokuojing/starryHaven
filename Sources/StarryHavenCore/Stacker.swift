import Foundation

public struct StackFrame: Sendable {
    public var image: ImageBuffer
    public var transform: Matrix3
    /// Optional per-pixel rejection mask (1 = exclude this frame at that pixel).
    public var mask: [Float]?

    public init(image: ImageBuffer, transform: Matrix3, mask: [Float]? = nil) {
        self.image = image
        self.transform = transform
        self.mask = mask
    }
}

public enum StackMethod: String, CaseIterable, Sendable {
    case mean = "均值"
    case median = "中值"
    case minimum = "最小值"
    case maximum = "最大值"
    case sigmaClipped = "Sigma 裁剪"
}

public struct StackOptions: Sendable {
    public var method: StackMethod = .sigmaClipped
    public var lowSigma: Double = 4.0
    public var highSigma: Double = 5.0
    public var cropToOverlap = false
    public var minimumCoverage: Float = 0.5
    public var bandHeight: Int = 96

    public init() {}
}

public struct StackResult: Sendable {
    public var image: ImageBuffer
    public var coverage: [Float]
    public var cropRect: CGRect
    public var frameCount: Int
}

public enum StackError: Error, CustomStringConvertible {
    case noFrames
    case emptyOverlap
    case warpFailed
    public var description: String {
        switch self {
        case .noFrames: return "没有可堆栈的帧"
        case .emptyOverlap: return "帧之间没有公共区域"
        case .warpFailed: return "图像变换失败"
        }
    }
}

public enum Stacker {
    public static func commonOverlap(frames: [StackFrame], fullWidth: Int, fullHeight: Int) -> CGRect {
        var common = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        for f in frames {
            let b = Warp.transformedBounds(width: f.image.width, height: f.image.height, imageToReference: f.transform)
            common = common.intersection(b)
            if common.isNull { return .zero }
        }
        let x0 = max(0, Int(ceil(common.minX)))
        let y0 = max(0, Int(ceil(common.minY)))
        let x1 = min(fullWidth, Int(floor(common.maxX)))
        let y1 = min(fullHeight, Int(floor(common.maxY)))
        if x1 <= x0 || y1 <= y0 { return .zero }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public static func stack(frames: [StackFrame],
                             fullWidth: Int,
                             fullHeight: Int,
                             options: StackOptions = StackOptions(),
                             progress: ((Double) -> Void)? = nil) throws -> StackResult {
        guard !frames.isEmpty else { throw StackError.noFrames }
        var outputRect = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        if options.cropToOverlap {
            outputRect = commonOverlap(frames: frames, fullWidth: fullWidth, fullHeight: fullHeight)
            guard outputRect.width >= 4, outputRect.height >= 4 else { throw StackError.emptyOverlap }
        }
        let outW = Int(outputRect.width), outH = Int(outputRect.height)
        var out = ImageBuffer(width: outW, height: outH, channels: 3)
        var coverageOut = [Float](repeating: 0, count: outW * outH)
        let bandHeight = max(16, min(options.bandHeight, outH))
        let totalFrames = Float(frames.count)
        var done = 0

        for bandY in stride(from: 0, to: outH, by: bandHeight) {
            let bh = min(bandHeight, outH - bandY)
            let region = CGRect(x: outputRect.minX, y: outputRect.minY + CGFloat(bandY), width: CGFloat(outW), height: CGFloat(bh))
            var warped: [(image: ImageBuffer, coverage: [Float])] = []
            warped.reserveCapacity(frames.count)
            for f in frames {
                guard let w = Warp.warpRegion(f.image, imageToReference: f.transform, region: region,
                                             fullWidth: fullWidth, fullHeight: fullHeight) else {
                    throw StackError.warpFailed
                }
                var coverage = w.coverage
                if let mask = f.mask, mask.count == f.image.count {
                    var maskImage = ImageBuffer(width: f.image.width, height: f.image.height, channels: 3)
                    for i in 0..<mask.count {
                        let v = mask[i]
                        maskImage.pixels[i * 3] = v
                        maskImage.pixels[i * 3 + 1] = v
                        maskImage.pixels[i * 3 + 2] = v
                    }
                    if let warpedMask = Warp.warpRegion(maskImage, imageToReference: f.transform, region: region,
                                                        fullWidth: fullWidth, fullHeight: fullHeight) {
                        for i in 0..<coverage.count where warpedMask.image.pixels[i * 3] > 0.5 {
                            coverage[i] = 0
                        }
                    }
                }
                warped.append((w.image, coverage))
            }
            for y in 0..<bh {
                for x in 0..<outW {
                    let dst = y * outW + x
                    let fullIndex = (bandY + y) * outW + x
                    var valid = 0
                    for w in warped where w.coverage[dst] >= options.minimumCoverage { valid += 1 }
                    coverageOut[fullIndex] = Float(valid) / totalFrames
                    for c in 0..<3 {
                        switch options.method {
                        case .mean:
                            var sum = 0.0, wsum = 0.0
                            for w in warped {
                                let weight = Double(w.coverage[dst])
                                if weight <= 0 { continue }
                                sum += Double(w.image.pixels[dst * 3 + c]) * weight
                                wsum += weight
                            }
                            out.pixels[(fullIndex) * 3 + c] = wsum > 0 ? Float(sum / wsum) : 0
                        case .median, .minimum, .maximum, .sigmaClipped:
                            var values: [Float] = []
                            values.reserveCapacity(warped.count)
                            for w in warped where w.coverage[dst] >= options.minimumCoverage {
                                let v = w.image.pixels[dst * 3 + c]
                                if v.isFinite { values.append(v) }
                            }
                            if values.isEmpty {
                                out.pixels[fullIndex * 3 + c] = 0
                                continue
                            }
                            switch options.method {
                            case .median:
                                out.pixels[fullIndex * 3 + c] = RGBMath.median(values)
                            case .minimum:
                                out.pixels[fullIndex * 3 + c] = values.min() ?? 0
                            case .maximum:
                                out.pixels[fullIndex * 3 + c] = values.max() ?? 0
                            case .sigmaClipped:
                                if values.count < 4 {
                                    var s: Float = 0
                                    for v in values { s += v }
                                    out.pixels[fullIndex * 3 + c] = s / Float(values.count)
                                } else {
                                    let (m, _) = RGBMath.sigmaClip(values, low: Float(options.lowSigma), high: Float(options.highSigma), iterations: 2)
                                    out.pixels[fullIndex * 3 + c] = m
                                }
                            default:
                                break
                            }
                        }
                    }
                }
            }
            done += bh
            progress?(Double(done) / Double(outH))
        }
        return StackResult(image: out, coverage: coverageOut, cropRect: outputRect, frameCount: frames.count)
    }
}
