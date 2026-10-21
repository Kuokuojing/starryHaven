import Foundation

public enum WhiteBalanceMode: String, CaseIterable, Sendable {
    case none = "不校正"
    case auto = "自动白平衡"
    case temperature = "色温"
}

public struct WhiteBalanceOptions: Sendable {
    public var mode: WhiteBalanceMode = .none
    public var temperature: Double = 4700
    public var tint: Double = 0
    public init() {}
}

public enum PostProcess {
    /// Linked screen-transfer stretch: percentile clip plus midtone transfer,
    /// applied equally to all channels so star colours are preserved.
    public static func stretch(_ image: ImageBuffer, targetBackground: Float = 0.25, strength: Float = 1.0) -> ImageBuffer {
        guard !image.pixels.isEmpty else { return image }
        let lum = image.luminance()
        var sorted = lum
        sorted.sort()
        let lo = sorted[max(0, Int(Double(sorted.count) * 0.002))]
        let hi = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.998))]
        let median = sorted[sorted.count / 2]
        let range = max(hi - lo, 1e-5)
        let normMedian = min(max((median - lo) / range, 0.0005), 0.5)
        let x: Float = 0.25
        let m = min(max(normMedian * (x - 1) / (2 * normMedian * x - x - normMedian), 0.0001), 0.9999)
        var out = image
        for i in 0..<image.count {
            for c in 0..<image.channels {
                let v = (image.pixels[i * image.channels + c] - lo) / range
                let stretched = DisplayTransform.mtfApply(max(v, 0), m)
                out.pixels[i * image.channels + c] = image.pixels[i * image.channels + c] * (1 - strength) + stretched * strength
            }
        }
        return out
    }

    public static func asinhStretch(_ image: ImageBuffer, strength: Float = 8, exposure: Float = 1) -> ImageBuffer {
        let denom = asinh(strength)
        var out = image
        for i in 0..<out.pixels.count {
            let v = max(out.pixels[i] * exposure, 0)
            out.pixels[i] = asinh(v * strength) / denom
        }
        return out
    }

    public static func whiteBalance(_ image: ImageBuffer, options: WhiteBalanceOptions) -> ImageBuffer {
        switch options.mode {
        case .none:
            return image
        case .auto:
            let bg = Calibration.background(image)
            let avg = (bg.x + bg.y + bg.z) / 3
            let gains = SIMD3<Float>(
                avg / max(bg.x, 1e-5),
                avg / max(bg.y, 1e-5),
                avg / max(bg.z, 1e-5)
            )
            return applyGains(image, gains: gains)
        case .temperature:
            let t = min(max(options.temperature, 1000), 20000)
            let ratio = Float(t / 6500.0)
            let r = sqrt(1.0 / ratio)
            let b = sqrt(ratio)
            let tint = Float(options.tint) / 100.0
            let g = 1.0 - tint * 0.15
            let gains = SIMD3<Float>(r, g, b)
            return applyGains(image, gains: gains)
        }
    }

    public static func applyGains(_ image: ImageBuffer, gains: SIMD3<Float>) -> ImageBuffer {
        var out = image
        let lumGain = 0.2126 * gains.x + 0.7152 * gains.y + 0.0722 * gains.z
        let norm = lumGain > 1e-6 ? gains / lumGain : gains
        for i in 0..<out.count {
            out.pixels[i * 3] = max(0, out.pixels[i * 3] * norm.x)
            out.pixels[i * 3 + 1] = max(0, out.pixels[i * 3 + 1] * norm.y)
            out.pixels[i * 3 + 2] = max(0, out.pixels[i * 3 + 2] * norm.z)
        }
        return out
    }

    public static func gaussianBlur(_ image: ImageBuffer, sigma: Double) -> ImageBuffer {
        guard sigma > 0.2 else { return image }
        // For large radii a kernel blur is O(sigma) per pixel; three box passes
        // approximate a Gaussian in O(1) per pixel and keep the UI responsive.
        if sigma > 4 {
            let r = max(1, Int(round(sqrt(12 * sigma * sigma / 3 + 1) / 2)))
            var out = image
            for _ in 0..<3 { out = boxBlur(out, radius: r) }
            return out
        }
        let radius = max(1, Int(ceil(sigma * 3)))
        var kernel = [Double](repeating: 0, count: radius * 2 + 1)
        var sum = 0.0
        for i in -radius...radius {
            let v = exp(-Double(i * i) / (2 * sigma * sigma))
            kernel[i + radius] = v
            sum += v
        }
        for i in 0..<kernel.count { kernel[i] /= sum }
        var temp = image
        var out = image
        let w = image.width, h = image.height
        for c in 0..<image.channels {
            for y in 0..<h {
                for x in 0..<w {
                    var s = 0.0
                    for k in -radius...radius {
                        let xx = min(max(x + k, 0), w - 1)
                        s += Double(image.pixels[(y * w + xx) * image.channels + c]) * kernel[k + radius]
                    }
                    temp.pixels[(y * w + x) * image.channels + c] = Float(s)
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    var s = 0.0
                    for k in -radius...radius {
                        let yy = min(max(y + k, 0), h - 1)
                        s += Double(temp.pixels[(yy * w + x) * image.channels + c]) * kernel[k + radius]
                    }
                    out.pixels[(y * w + x) * image.channels + c] = Float(s)
                }
            }
        }
        return out
    }

    private static func boxBlur(_ image: ImageBuffer, radius: Int) -> ImageBuffer {
        let w = image.width, h = image.height, ch = image.channels
        var temp = image
        var out = image
        let norm = Float(2 * radius + 1)
        for c in 0..<ch {
            for y in 0..<h {
                var sum: Float = 0
                for k in -radius...radius {
                    let x = min(max(k, 0), w - 1)
                    sum += image.pixels[(y * w + x) * ch + c]
                }
                for x in 0..<w {
                    temp.pixels[(y * w + x) * ch + c] = sum / norm
                    let addX = min(x + radius + 1, w - 1)
                    let subX = min(max(x - radius, 0), w - 1)
                    sum += image.pixels[(y * w + addX) * ch + c] - image.pixels[(y * w + subX) * ch + c]
                }
            }
            for x in 0..<w {
                var sum: Float = 0
                for k in -radius...radius {
                    let y = min(max(k, 0), h - 1)
                    sum += temp.pixels[(y * w + x) * ch + c]
                }
                for y in 0..<h {
                    out.pixels[(y * w + x) * ch + c] = sum / norm
                    let addY = min(y + radius + 1, h - 1)
                    let subY = min(max(y - radius, 0), h - 1)
                    sum += temp.pixels[(addY * w + x) * ch + c] - temp.pixels[(subY * w + x) * ch + c]
                }
            }
        }
        return out
    }

    /// Star reduction: subtract the small-scale bright layer (stars) and
    /// optionally replace it with a softened version.
    public static func starReduction(_ image: ImageBuffer, amount: Double = 0.5, softening: Double = 0, radiusScale: Double = 1.0) -> ImageBuffer {
        let amount = min(max(amount, 0), 1)
        guard amount > 0 || softening > 0 else { return image }
        let lum = image.luminance()
        var sorted = lum
        sorted.sort()
        let median = sorted[sorted.count / 2]
        var highPass = ImageBuffer(width: image.width, height: image.height, channels: 3)
        let blur = gaussianBlur(image, sigma: max(1.5, 2.2 * radiusScale))
        for i in 0..<image.count {
            for c in 0..<3 {
                highPass.pixels[i * 3 + c] = max(0, image.pixels[i * 3 + c] - blur.pixels[i * 3 + c])
            }
        }
        // Suppress the high-pass in faint background texture; stars are far brighter.
        var out = image
        let threshold = Float(max(median * 0.04, 0.002))
        let soft = gaussianBlur(highPass, sigma: 1.2)
        for i in 0..<image.count {
            let strength = min(max(Double(lum[i] - median) / 0.4, 0), 1)
            for c in 0..<3 {
                let hp = highPass.pixels[i * 3 + c]
                let gate = hp > threshold ? 1.0 : max(0, Double(hp / threshold))
                let reduce = Float(amount * strength * gate)
                let addSoft = Float(softening * strength * gate)
                out.pixels[i * 3 + c] = max(0, out.pixels[i * 3 + c] - hp * reduce + soft.pixels[i * 3 + c] * addSoft)
            }
        }
        return out
    }

    /// Removes the smooth background (2nd-order polynomial per channel) and
    /// optionally re-normalizes the per-channel background level.
    public static func backgroundBalance(_ image: ImageBuffer, grid: Int = 8, degree: Int = 2, keepLevel: Bool = true) -> ImageBuffer {
        let bg = Calibration.background(image)
        var out = Calibration.backgroundExtract(image, grid: grid, degree: degree)
        if keepLevel {
            let after = Calibration.background(out)
            for i in 0..<out.count {
                for c in 0..<3 { out.pixels[i * 3 + c] += bg[c] - after[c] }
            }
        }
        return out
    }

    public static func skyOnly(original: ImageBuffer, effect: ImageBuffer, mask: SkyMask) -> ImageBuffer {
        SkyComposite.skyOnly(original: original, effect: effect, mask: mask)
    }
}

public struct EnhancementOptions: Sendable {
    public var localContrast: Double = 0
    public var structure: Double = 0
    public var structureRadius: Double = 30
    public var skylight: Double = 0
    public var glow: Double = 0
    public var glowRadius: Double = 2
    public init() {}
}

extension PostProcess {
    /// Local contrast, structure enhancement, atmospheric skylight reduction
    /// and star-trail glow. All amounts are 0...1 (glow 0...10) and operate on
    /// display-referred data, matching the toolbox preview pipeline.
    public static func enhance(_ image: ImageBuffer, options: EnhancementOptions, mask: SkyMask? = nil) -> ImageBuffer {
        var out = image
        if options.localContrast > 0 {
            let blur = gaussianBlur(image, sigma: 2.2)
            let amount = Float(min(options.localContrast, 1) * 1.6)
            for i in 0..<out.pixels.count {
                let d = image.pixels[i] - blur.pixels[i]
                out.pixels[i] = min(max(image.pixels[i] + d * amount, 0), 1)
            }
        }
        if options.structure > 0 {
            let radius = max(3, options.structureRadius)
            let blur = gaussianBlur(out, sigma: radius)
            let amount = Float(min(options.structure, 1) * 1.2)
            for i in 0..<out.pixels.count {
                let d = min(max(out.pixels[i] - blur.pixels[i], -0.12), 0.12)
                out.pixels[i] = min(max(out.pixels[i] + d * amount, 0), 1)
            }
        }
        if options.skylight > 0 {
            let amount = Float(min(options.skylight, 1))
            for i in 0..<out.count {
                let r = out.pixels[i * 3], g = out.pixels[i * 3 + 1], b = out.pixels[i * 3 + 2]
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let haze = max(0, b - max(r, g))
                let shadowWeight = max(0, 1 - lum * 1.8)
                out.pixels[i * 3 + 2] = max(0, b - haze * amount * shadowWeight * 0.8)
            }
        }
        if options.glow > 0 {
            out = starTrailGlow(out, amount: options.glow, radius: options.glowRadius)
        }
        if let mask = mask {
            return SkyComposite.skyOnly(original: image, effect: out, mask: mask)
        }
        return out
    }

    /// Adds a soft halo around bright structures (star-trail glow).
    public static func starTrailGlow(_ image: ImageBuffer, amount: Double, radius: Double) -> ImageBuffer {
        guard amount > 0 else { return image }
        var highlights = image
        for i in 0..<highlights.count {
            let lum = 0.2126 * image.pixels[i * 3] + 0.7152 * image.pixels[i * 3 + 1] + 0.0722 * image.pixels[i * 3 + 2]
            let w = Float(max(0, min(1, (Double(lum) - 0.45) / 0.55)))
            for c in 0..<3 { highlights.pixels[i * 3 + c] = image.pixels[i * 3 + c] * w }
        }
        let blurred = gaussianBlur(highlights, sigma: max(0.5, min(radius, 12)))
        var out = image
        let a = Float(min(max(amount, 0), 10))
        for i in 0..<out.pixels.count {
            out.pixels[i] = min(max(out.pixels[i] + blurred.pixels[i] * a, 0), 1)
        }
        return out
    }
}
