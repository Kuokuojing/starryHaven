import Foundation

/// Deterministic synthetic scene generation used by the self-test, the CLI and
/// the test suite. These are generators, not substitutes for the processing code.
public enum SyntheticScene {
    public struct Random {
        private var state: UInt64
        public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        public mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        public mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        public mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * uniform() }
        public mutating func gaussian() -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return sqrt(-2 * log(u1)) * cos(2 * Double.pi * u2)
        }
    }

    public struct StarSpec {
        public var x: Double
        public var y: Double
        public var peak: Double
        public var sigma: Double
        public var color: SIMD3<Double>
        public init(x: Double, y: Double, peak: Double, sigma: Double, color: SIMD3<Double> = SIMD3(1, 1, 1)) {
            self.x = x; self.y = y; self.peak = peak; self.sigma = sigma; self.color = color
        }
    }

    public static func randomStars(width: Int, height: Int, count: Int, seed: UInt64,
                                   minSeparation: Double = 9, sigmaRange: ClosedRange<Double> = 1.2...2.4,
                                   peakRange: ClosedRange<Double> = 0.08...0.95) -> [StarSpec] {
        var rng = Random(seed: seed)
        var stars: [StarSpec] = []
        var attempts = 0
        while stars.count < count && attempts < count * 400 {
            attempts += 1
            let x = rng.uniform(12, Double(width - 12))
            let y = rng.uniform(12, Double(height - 12))
            if stars.contains(where: { hypot($0.x - x, $0.y - y) < minSeparation }) { continue }
            let peak = rng.uniform(peakRange.lowerBound, peakRange.upperBound)
            // Power-law-ish brightness distribution.
            let bright = pow(rng.uniform(), 2.2)
            let p = peakRange.lowerBound + (peakRange.upperBound - peakRange.lowerBound) * bright
            _ = peak
            let sigma = rng.uniform(sigmaRange.lowerBound, sigmaRange.upperBound)
            let warmth = rng.uniform(-0.08, 0.08)
            stars.append(StarSpec(x: x, y: y, peak: p, sigma: sigma,
                                  color: SIMD3(1.0 + warmth, 1.0, 1.0 - warmth * 0.6)))
        }
        return stars
    }

    /// Renders a star field with additive Gaussian PSFs, background and noise.
    public static func starField(width: Int, height: Int, stars: [StarSpec],
                                 background: Double = 0.02, backgroundGradient: Double = 0.0,
                                 noise: Double = 0.002, seed: UInt64 = 1,
                                 extraNoise: Double = 0) -> ImageBuffer {
        var img = ImageBuffer(width: width, height: height, channels: 3)
        var rng = Random(seed: seed)
        for y in 0..<height {
            let bg = background + backgroundGradient * Double(y) / Double(max(height - 1, 1))
            for x in 0..<width {
                let v = Float(bg)
                let i = (y * width + x) * 3
                img.pixels[i] = v; img.pixels[i + 1] = v; img.pixels[i + 2] = v
            }
        }
        for s in stars {
            addStar(to: &img, s)
        }
        if noise > 0 {
            for i in 0..<(width * height * 3) {
                let n = Float(rng.gaussian() * noise + (extraNoise > 0 ? rng.gaussian() * extraNoise : 0))
                img.pixels[i] = max(0, img.pixels[i] + n)
            }
        }
        return img
    }

    public static func addStar(to image: inout ImageBuffer, _ s: StarSpec) {
        let r = Int(ceil(s.sigma * 4))
        let x0 = max(0, Int(floor(s.x)) - r), x1 = min(image.width - 1, Int(ceil(s.x)) + r)
        let y0 = max(0, Int(floor(s.y)) - r), y1 = min(image.height - 1, Int(ceil(s.y)) + r)
        guard x0 <= x1, y0 <= y1 else { return }
        let twoSigma2 = 2 * s.sigma * s.sigma
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = Double(x) - s.x, dy = Double(y) - s.y
                let v = s.peak * exp(-(dx * dx + dy * dy) / twoSigma2)
                let i = image.index(x, y, 0)
                image.pixels[i] += Float(v * s.color.x)
                image.pixels[i + 1] += Float(v * s.color.y)
                image.pixels[i + 2] += Float(v * s.color.z)
            }
        }
    }

    public static func addSatelliteTrail(to image: inout ImageBuffer, from p0: (Double, Double), to p1: (Double, Double), brightness: Double = 0.55, width: Double = 0.8) {
        let steps = Int(hypot(p1.0 - p0.0, p1.1 - p0.1) * 2) + 1
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = p0.0 + (p1.0 - p0.0) * t
            let y = p0.1 + (p1.1 - p0.1) * t
            let x0 = max(0, Int(x - 2)), x1 = min(image.width - 1, Int(x + 2))
            let y0 = max(0, Int(y - 2)), y1 = min(image.height - 1, Int(y + 2))
            if x0 > x1 || y0 > y1 { continue }
            for yy in y0...y1 {
                for xx in x0...x1 {
                    let d = hypot(Double(xx) - x, Double(yy) - y)
                    let v = brightness * exp(-(d * d) / (2 * width * width))
                    let idx = image.index(xx, yy, 0)
                    for c in 0..<3 { image.pixels[idx + c] += Float(v) }
                }
            }
        }
    }

    /// Synthetic horizon: a smooth sky above and textured ground below. Returns
    /// the image plus 1.0 where the pixel belongs to the ground.
    public static func horizonScene(width: Int, height: Int, horizonY: Int, seed: UInt64 = 7,
                                    addStars: Bool = true) -> (image: ImageBuffer, ground: [Float]) {
        var img = ImageBuffer(width: width, height: height, channels: 3)
        var rng = Random(seed: seed)
        var ground = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                if y < horizonY {
                    let t = Double(y) / Double(max(horizonY - 1, 1))
                    let glow = 0.18 * exp(-pow((Double(x) - Double(width) * 0.35) / (Double(width) * 0.25), 2))
                    img.pixels[i] = Float(0.16 + 0.24 * t + glow)
                    img.pixels[i + 1] = Float(0.20 + 0.26 * t + glow * 1.1)
                    img.pixels[i + 2] = Float(0.36 + 0.22 * t + glow * 1.4)
                } else {
                    let n = rng.gaussian() * 0.015
                    let stripe = 0.025 * Double((x / 23) % 3)
                    let tex = 0.02 * sin(Double(x) * 0.11) * cos(Double(y) * 0.07)
                    img.pixels[i] = Float(0.075 + n + stripe + tex)
                    img.pixels[i + 1] = Float(0.085 + n + stripe * 0.8 + tex)
                    img.pixels[i + 2] = Float(0.055 + n + stripe * 0.5)
                    ground[y * width + x] = 1
                }
            }
        }
        if addStars {
            var stars = randomStars(width: width, height: max(horizonY, 1), count: 45, seed: seed &+ 3,
                                    minSeparation: 12, peakRange: 0.25...0.9)
            // Keep stars above the horizon.
            stars = stars.filter { $0.y < Double(horizonY - 4) }
            for s in stars { addStar(to: &img, s) }
        }
        return (img, ground)
    }

    /// A smooth nebula-like structure for structure-preservation checks.
    public static func addNebula(to image: inout ImageBuffer, center: (Double, Double), radius: Double, brightness: Double) {
        for y in 0..<image.height {
            for x in 0..<image.width {
                let dx = Double(x) - center.0, dy = Double(y) - center.1
                let r2 = (dx * dx + dy * dy) / (radius * radius)
                let v = brightness * exp(-r2 * 1.4)
                let i = image.index(x, y, 0)
                image.pixels[i] += Float(v)
                image.pixels[i + 1] += Float(v * 0.85)
                image.pixels[i + 2] += Float(v * 1.15)
            }
        }
    }
}
