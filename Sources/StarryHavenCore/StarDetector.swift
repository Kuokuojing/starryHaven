import Foundation

public struct Star: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var flux: Double
    public var fwhm: Double
    public var peak: Double

    public init(x: Double, y: Double, flux: Double, fwhm: Double, peak: Double) {
        self.x = x; self.y = y; self.flux = flux; self.fwhm = fwhm; self.peak = peak
    }
}

public struct StarField: Sendable {
    public var stars: [Star]
    public var background: Double
    public var noise: Double
}

public struct DetectionOptions: Sendable {
    public var thresholdSigma: Double = 5.0
    public var maxStars: Int = 250
    public var minFWHM: Double = 0.8
    public var maxFWHM: Double = 14.0
    public var maxCandidates: Int = 3000
    public var fitRadius: Int = 4

    public init() {}
}

public enum StarDetector {
    /// Robust background and per-pixel noise estimate (median / MAD).
    public static func backgroundEstimate(_ lum: [Float]) -> (background: Double, noise: Double) {
        guard !lum.isEmpty else { return (0, 0) }
        let stride = max(1, lum.count / 400_000)
        var sample: [Float] = []
        sample.reserveCapacity(lum.count / stride + 1)
        var i = 0
        while i < lum.count {
            let v = lum[i]
            if v.isFinite { sample.append(v) }
            i += stride
        }
        guard !sample.isEmpty else { return (0, 0) }
        sample.sort()
        func percentile(_ p: Double) -> Double {
            let idx = min(max(Int(Double(sample.count - 1) * p), 0), sample.count - 1)
            return Double(sample[idx])
        }
        var lo = percentile(0.10)
        var hi = percentile(0.90)
        // Two refinement passes keep bright stars out of the background estimate.
        for _ in 0..<2 {
            var kept: [Float] = []
            kept.reserveCapacity(sample.count)
            for v in sample where Double(v) >= lo && Double(v) <= hi {
                kept.append(v)
            }
            if kept.count < 32 { break }
            let med = Double(kept[kept.count / 2])
            var dev: [Float] = []
            dev.reserveCapacity(kept.count)
            for v in kept { dev.append(Float(abs(Double(v) - med))) }
            dev.sort()
            let mad = Double(dev[dev.count / 2])
            let sigma = max(mad * 1.4826, 1e-7)
            lo = med - 4 * sigma
            hi = med + 4 * sigma
            if hi - lo < 1e-9 { break }
        }
        var kept: [Float] = []
        for v in sample where Double(v) >= lo && Double(v) <= hi { kept.append(v) }
        let base = kept.isEmpty ? sample : kept
        let med = Double(base[base.count / 2])
        var dev: [Float] = []
        dev.reserveCapacity(base.count)
        for v in base { dev.append(Float(abs(Double(v) - med))) }
        dev.sort()
        let mad = Double(dev[dev.count / 2])
        return (med, max(mad * 1.4826, 1e-7))
    }

    public static func detect(image: ImageBuffer, options: DetectionOptions = DetectionOptions()) -> StarField {
        detect(luminance: image.luminance(), width: image.width, height: image.height, options: options)
    }

    public static func detect(luminance lum: [Float], width: Int, height: Int, options: DetectionOptions = DetectionOptions()) -> StarField {
        guard width > 8, height > 8, lum.count == width * height else {
            return StarField(stars: [], background: 0, noise: 0)
        }
        let (bg, noise) = backgroundEstimate(lum)
        let threshold = Float(bg + options.thresholdSigma * noise)

        // 3x3 binomial smoothing for peak finding only; centroids use the raw data.
        var smooth = [Float](repeating: 0, count: lum.count)
        let w = width
        for y in 0..<height {
            let ym = max(y - 1, 0), yp = min(y + 1, height - 1)
            for x in 0..<width {
                let xm = max(x - 1, 0), xp = min(x + 1, width - 1)
                let v = lum[ym * w + xm] + 2 * lum[ym * w + x] + lum[ym * w + xp]
                    + 2 * lum[y * w + xm] + 4 * lum[y * w + x] + 2 * lum[y * w + xp]
                    + lum[yp * w + xm] + 2 * lum[yp * w + x] + lum[yp * w + xp]
                smooth[y * w + x] = v / 16
            }
        }

        var candidates: [(x: Int, y: Int, value: Float)] = []
        candidates.reserveCapacity(4096)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let v = smooth[y * w + x]
                if v < threshold { continue }
                var isMax = true
                for dy in -1...1 where isMax {
                    for dx in -1...1 where isMax {
                        if dx == 0 && dy == 0 { continue }
                        let n = smooth[(y + dy) * w + (x + dx)]
                        if n > v || (n == v && (dy < 0 || (dy == 0 && dx < 0))) {
                            isMax = false
                        }
                    }
                }
                if isMax { candidates.append((x, y, v)) }
            }
        }
        candidates.sort { $0.value > $1.value }
        if candidates.count > options.maxCandidates {
            candidates.removeSubrange(options.maxCandidates..<candidates.count)
        }

        var stars: [Star] = []
        stars.reserveCapacity(candidates.count)
        let border = 4
        for c in candidates {
            if c.x < border || c.y < border || c.x >= width - border || c.y >= height - border { continue }
            guard let star = fitStar(lum: lum, width: width, height: height, cx: c.x, cy: c.y, background: bg, noise: noise, radius: options.fitRadius) else { continue }
            if star.fwhm < options.minFWHM || star.fwhm > options.maxFWHM { continue }
            if star.flux <= 0 { continue }
            stars.append(star)
        }
        stars.sort { $0.flux > $1.flux }
        if stars.count > options.maxStars { stars.removeSubrange(options.maxStars..<stars.count) }
        return StarField(stars: stars, background: bg, noise: noise)
    }

    /// Least-squares 2D Gaussian fit on a small window, falling back to moments.
    public static func fitStar(lum: [Float], width: Int, height: Int, cx: Int, cy: Int, background: Double, noise: Double, radius: Int = 4) -> Star? {
        let r = min(max(radius, 2), 6)
        let x0 = cx - r, y0 = cy - r
        guard x0 > 0, y0 > 0, cx + r < width - 1, cy + r < height - 1 else { return nil }
        let n = (2 * r + 1) * (2 * r + 1)
        var xs = [Double](repeating: 0, count: n)
        var ys = [Double](repeating: 0, count: n)
        var vs = [Double](repeating: 0, count: n)
        var k = 0
        var peak: Float = 0
        for y in (cy - r)...(cy + r) {
            for x in (cx - r)...(cx + r) {
                xs[k] = Double(x)
                ys[k] = Double(y)
                vs[k] = Double(lum[y * width + x])
                peak = max(peak, lum[y * width + x])
                k += 1
            }
        }

        // Moments for initialization.
        var sum = 0.0, sx = 0.0, sy = 0.0
        let localBg = min(background, Double(peak) * 0.5)
        for i in 0..<n {
            let wgt = max(vs[i] - localBg, 0)
            sum += wgt; sx += wgt * xs[i]; sy += wgt * ys[i]
        }
        guard sum > 0 else { return nil }
        let mx = sx / sum, my = sy / sum
        var vx = 0.0, vy = 0.0
        for i in 0..<n {
            let wgt = max(vs[i] - localBg, 0)
            vx += wgt * (xs[i] - mx) * (xs[i] - mx)
            vy += wgt * (ys[i] - my) * (ys[i] - my)
        }
        var sxx = max(vx / sum, 0.35)
        var syy = max(vy / sum, 0.35)

        var params = [background, max(Double(peak) - background, 1e-6), mx, my, 1 / (2 * sxx), 1 / (2 * syy)]
        let converged = gaussNewton(xs: xs, ys: ys, vs: vs, params: &params, iterations: 18)
        var fwhm = 0.0
        if converged {
            let a = params[4], c = params[5]
            if a > 1e-6 && c > 1e-6 {
                sxx = sqrt(1 / (2 * a)); syy = sqrt(1 / (2 * c))
                fwhm = 2.354820045 * sqrt(sxx * syy)
                if params[2] > Double(cx - r) - 0.5 && params[2] < Double(cx + r) + 0.5 &&
                    params[3] > Double(cy - r) - 0.5 && params[3] < Double(cy + r) + 0.5 {
                    // Use fitted centroid.
                } else {
                    fwhm = 0
                }
            }
        }
        if fwhm <= 0 || !fwhm.isFinite {
            fwhm = 2.354820045 * sqrt(sxx * syy)
            params[2] = mx; params[3] = my
        }

        // Aperture flux with a local sky annulus.
        let ap = max(2, Int(ceil(fwhm * 1.2)))
        var flux = 0.0
        var bgSamples: [Float] = []
        for y in max(cy - ap - 3, 0)...min(cy + ap + 3, height - 1) {
            for x in max(cx - ap - 3, 0)...min(cx + ap + 3, width - 1) {
                let d = sqrt(Double((x - cx) * (x - cx) + (y - cy) * (y - cy)))
                if d <= Double(ap) {
                    flux += Double(lum[y * width + x])
                } else if d <= Double(ap + 2) {
                    bgSamples.append(lum[y * width + x])
                }
            }
        }
        let sky = bgSamples.isEmpty ? background : Double(RGBMath.median(bgSamples))
        let area = Double.pi * Double(ap) * Double(ap)
        flux -= sky * area
        if !flux.isFinite { flux = 0 }
        return Star(x: params[2], y: params[3], flux: flux, fwhm: fwhm, peak: Double(peak))
    }

    private static func gaussNewton(xs: [Double], ys: [Double], vs: [Double], params: inout [Double], iterations: Int) -> Bool {
        let n = xs.count
        var lambda = 1e-3
        var lastError = Double.greatestFiniteMagnitude
        for _ in 0..<iterations {
            var jtj = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
            var jtr = [Double](repeating: 0, count: 6)
            var error = 0.0
            for i in 0..<n {
                let du = xs[i] - params[2]
                let dv = ys[i] - params[3]
                let a = max(params[4], 1e-6), c = max(params[5], 1e-6)
                let q = a * du * du + c * dv * dv
                let e = exp(-min(q, 60))
                let model = params[0] + params[1] * e
                let res = model - vs[i]
                error += res * res
                let j = [1.0, e,
                         params[1] * e * (2 * a * du),
                         params[1] * e * (2 * c * dv),
                         -params[1] * e * du * du,
                         -params[1] * e * dv * dv]
                for p in 0..<6 {
                    jtr[p] += j[p] * res
                    for q2 in 0..<6 { jtj[p][q2] += j[p] * j[q2] }
                }
            }
            if !error.isFinite { return false }
            for p in 0..<6 { jtj[p][p] += lambda * (jtj[p][p] + 1e-9) }
            guard let delta = solve6(jtj, jtr.map { -$0 }) else { return false }
            var trial = params
            for p in 0..<6 { trial[p] += delta[p] }
            trial[1] = max(trial[1], 0)
            trial[4] = max(trial[4], 1e-4)
            trial[5] = max(trial[5], 1e-4)
            // Reject non-physical aspect ratios.
            let ratio = trial[4] / trial[5]
            if ratio < 0.2 || ratio > 5 { trial[4] = params[4]; trial[5] = params[5] }
            var trialError = 0.0
            for i in 0..<n {
                let du = xs[i] - trial[2], dv = ys[i] - trial[3]
                let q = trial[4] * du * du + trial[5] * dv * dv
                let model = trial[0] + trial[1] * exp(-min(q, 60))
                let res = model - vs[i]
                trialError += res * res
            }
            if trialError < error {
                params = trial
                lambda = max(lambda * 0.3, 1e-9)
                if abs(lastError - trialError) < 1e-10 * max(trialError, 1) { return true }
                lastError = trialError
            } else {
                lambda *= 10
                if lambda > 1e6 { return false }
            }
        }
        return lastError.isFinite
    }

    private static func solve6(_ aIn: [[Double]], _ bIn: [Double]) -> [Double]? {
        var a = aIn
        var b = bIn
        let n = 6
        for col in 0..<n {
            var pivot = col
            var best = abs(a[col][col])
            for row in (col + 1)..<n where abs(a[row][col]) > best {
                best = abs(a[row][col]); pivot = row
            }
            if best < 1e-14 { return nil }
            if pivot != col {
                a.swapAt(pivot, col); b.swapAt(pivot, col)
            }
            let d = a[col][col]
            for j in col..<n { a[col][j] /= d }
            b[col] /= d
            for row in 0..<n where row != col {
                let f = a[row][col]
                if f == 0 { continue }
                for j in col..<n { a[row][j] -= f * a[col][j] }
                b[row] -= f * b[col]
            }
        }
        return b
    }
}
