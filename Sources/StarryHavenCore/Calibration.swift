import Foundation

public struct CalibrationOptions: Sendable {
    public var applyBias = true
    public var applyDark = true
    public var applyFlat = true
    public var darkScale: Double = 1.0
    public var badPixelCorrection = true
    public var normalizeBackground = true

    public init() {}
}

public struct CalibrationMasters: Sendable {
    public var bias: ImageBuffer?
    public var dark: ImageBuffer?
    public var flat: ImageBuffer?
    public var badPixels: [Float]?

    public init(bias: ImageBuffer? = nil, dark: ImageBuffer? = nil, flat: ImageBuffer? = nil, badPixels: [Float]? = nil) {
        self.bias = bias
        self.dark = dark
        self.flat = flat
        self.badPixels = badPixels
    }
}

public enum Calibration {
    /// Builds a master frame by per-pixel sigma-clipped mean. `subtract` is
    /// removed from every input first (bias for dark, bias+dark for flat).
    public static func master(frames: [ImageBuffer], subtract: ImageBuffer? = nil, sigma: Double = 3.0) -> ImageBuffer? {
        guard let first = frames.first else { return nil }
        let w = first.width, h = first.height, ch = first.channels
        var out = ImageBuffer(width: w, height: h, channels: ch)
        var values = [Float](repeating: 0, count: frames.count)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<ch {
                    for (i, f) in frames.enumerated() {
                        var v = f[x, y, c]
                        if let s = subtract {
                            if s.width == w && s.height == h { v -= s[x, y, c] }
                        }
                        values[i] = v
                    }
                    let (m, _) = RGBMath.sigmaClip(values, low: Float(sigma), high: Float(sigma), iterations: 2)
                    out[x, y, c] = m
                }
            }
        }
        return out
    }

    /// Builds a normalized flat master (mean 1.0 per channel).
    public static func flatMaster(frames: [ImageBuffer], bias: ImageBuffer?, dark: ImageBuffer?, darkScale: Double = 1.0) -> ImageBuffer? {
        guard let raw = master(frames: frames, subtract: nil) else { return nil }
        var flat = raw
        if let b = bias, b.width == flat.width, b.height == flat.height {
            for i in 0..<flat.pixels.count { flat.pixels[i] -= b.pixels[i] }
        }
        if let d = dark, d.width == flat.width, d.height == flat.height {
            for i in 0..<flat.pixels.count { flat.pixels[i] -= Float(darkScale) * d.pixels[i] }
        }
        for c in 0..<flat.channels {
            let ch = flat.channel(c)
            let sorted = ch.sorted()
            let med = sorted[sorted.count / 2]
            let denom = max(med, 1e-4)
            for i in 0..<flat.count { flat.pixels[i * flat.channels + c] = max(flat.pixels[i * flat.channels + c] / denom, 0.05) }
        }
        return flat
    }

    /// Hot/dead pixel map from dark and flat masters.
    public static func badPixelMask(dark: ImageBuffer?, flat: ImageBuffer?, hotSigma: Double = 8.0) -> [Float] {
        guard let dark = dark, let flat = flat, dark.width == flat.width, dark.height == flat.height else {
            return [Float](repeating: 0, count: flat?.count ?? 0)
        }
        var mask = [Float](repeating: 0, count: dark.count)
        let d = dark.luminance()
        let med = RGBMath.median(d)
        let mad = RGBMath.mad(d, median: med)
        let hot = Double(med) + max(hotSigma * Double(mad) * 1.4826, 0.002)
        for i in 0..<d.count {
            if Double(d[i]) > hot { mask[i] = 1 }
        }
        for i in 0..<flat.count {
            // A flat below 0.4 means the pixel sees much less light than its neighbours.
            if flat.pixels[i * flat.channels] < 0.4 && flat.pixels[i * flat.channels + 1] < 0.4 && flat.pixels[i * flat.channels + 2] < 0.4 {
                mask[i] = 1
            }
        }
        return mask
    }

    public static func calibrate(light: ImageBuffer, masters: CalibrationMasters, options: CalibrationOptions) -> ImageBuffer {
        var out = light
        let w = light.width, h = light.height
        if options.applyBias, let b = masters.bias, b.width == w, b.height == h {
            for i in 0..<out.pixels.count { out.pixels[i] -= b.pixels[i] }
        }
        if options.applyDark, let d = masters.dark, d.width == w, d.height == h {
            let s = Float(options.darkScale)
            for i in 0..<out.pixels.count { out.pixels[i] -= s * d.pixels[i] }
        }
        if options.applyFlat, let f = masters.flat, f.width == w, f.height == h {
            for i in 0..<out.pixels.count {
                out.pixels[i] = out.pixels[i] / max(f.pixels[i], 0.05)
            }
        }
        if options.badPixelCorrection, let mask = masters.badPixels, mask.count == out.count {
            correctBadPixels(&out, mask: mask)
        }
        return out
    }

    public static func correctBadPixels(_ image: inout ImageBuffer, mask: [Float]) {
        let w = image.width, h = image.height, ch = image.channels
        let original = image
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where mask[y * w + x] > 0.5 {
                for c in 0..<ch {
                    var neighbours: [Float] = []
                    neighbours.reserveCapacity(8)
                    for dy in -1...1 {
                        for dx in -1...1 {
                            if dx == 0 && dy == 0 { continue }
                            if mask[(y + dy) * w + (x + dx)] > 0.5 { continue }
                            neighbours.append(original[x + dx, y + dy, c])
                        }
                    }
                    if !neighbours.isEmpty {
                        image[x, y, c] = RGBMath.median(neighbours)
                    }
                }
            }
        }
    }

    /// Per-channel robust background, ignoring stars and the top 40% of values.
    public static func background(_ image: ImageBuffer, mask: [Float]? = nil) -> SIMD3<Float> {
        var result = SIMD3<Float>(repeating: 0)
        let luminance = image.luminance()
        var sortedLum = luminance
        sortedLum.sort()
        let cutoff = sortedLum[min(sortedLum.count - 1, Int(Double(sortedLum.count) * 0.6))]
        for c in 0..<image.channels {
            var values: [Float] = []
            values.reserveCapacity(image.count / 2)
            for i in 0..<image.count {
                if luminance[i] <= cutoff, mask?[i] ?? 0 < 0.5, image.pixels[i * image.channels + c].isFinite {
                    values.append(image.pixels[i * image.channels + c])
                }
            }
            result[c] = values.isEmpty ? 0 : RGBMath.median(values)
        }
        return result
    }

    /// Offsets a frame so its background matches `reference`.
    public static func normalizeBackground(_ image: ImageBuffer, to reference: SIMD3<Float>) -> ImageBuffer {
        let bg = background(image)
        var out = image
        for i in 0..<out.count {
            for c in 0..<out.channels {
                out.pixels[i * out.channels + c] += reference[c] - bg[c]
            }
        }
        return out
    }

    /// Estimates and subtracts a smooth additive gradient (2nd-order polynomial
    /// per channel) from a grid of sky samples.
    public static func backgroundExtract(_ image: ImageBuffer, grid: Int = 8, degree: Int = 2) -> ImageBuffer {
        let w = image.width, h = image.height
        let gx = max(3, grid), gy = max(3, grid)
        var samples: [(x: Double, y: Double, values: SIMD3<Double>)] = []
        for row in 0..<gy {
            for col in 0..<gx {
                let x0 = col * w / gx, x1 = max(x0 + 1, (col + 1) * w / gx)
                let y0 = row * h / gy, y1 = max(y0 + 1, (row + 1) * h / gy)
                var v = SIMD3<Double>(repeating: 0)
                var n = 0.0
                for y in stride(from: y0, to: y1, by: 2) {
                    for x in stride(from: x0, to: x1, by: 2) {
                        let p = image.pixel(x: x, y: y)
                        v += SIMD3(Double(p.x), Double(p.y), Double(p.z))
                        n += 1
                    }
                }
                if n > 0 {
                    let cx = (Double(x0) + Double(x1 - 1)) * 0.5 / Double(max(w - 1, 1))
                    let cy = (Double(y0) + Double(y1 - 1)) * 0.5 / Double(max(h - 1, 1))
                    samples.append((cx, cy, v / n))
                }
            }
        }
        // Fit each channel: p = c0 + c1*x + c2*y + c3*x² + c4*xy + c5*y² (+ cubic terms when degree=3).
        let terms = degree >= 3 ? 10 : 6
        func basis(_ x: Double, _ y: Double) -> [Double] {
            if degree >= 3 {
                return [1, x, y, x * x, x * y, y * y, x * x * x, x * x * y, x * y * y, y * y * y]
            }
            return [1, x, y, x * x, x * y, y * y]
        }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: terms), count: terms)
        var atb = [[Double]](repeating: [Double](repeating: 0, count: terms), count: 3)
        for s in samples {
            let b = basis(s.x, s.y)
            for r in 0..<terms {
                for c in 0..<terms { ata[r][c] += b[r] * b[c] }
                for ch in 0..<3 {
                    atb[ch][r] += b[r] * (ch == 0 ? s.values.x : (ch == 1 ? s.values.y : s.values.z))
                }
            }
        }
        var coeffs = [[Double]]()
        for ch in 0..<3 {
            coeffs.append(TransformFit.solveLinear(ata, atb[ch]) ?? [Double](repeating: 0, count: terms))
        }
        var out = image
        for y in 0..<h {
            let ny = Double(y) / Double(max(h - 1, 1))
            for x in 0..<w {
                let nx = Double(x) / Double(max(w - 1, 1))
                let b = basis(nx, ny)
                for c in 0..<3 {
                    var fit = 0.0
                    for i in 0..<terms { fit += coeffs[c][i] * b[i] }
                    out.pixels[(y * w + x) * 3 + c] -= Float(fit)
                }
            }
        }
        return out
    }
}
