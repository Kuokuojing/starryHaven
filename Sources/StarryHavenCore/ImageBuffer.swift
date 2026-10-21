import Foundation
import Accelerate

/// Interleaved float32 RGB image in linear light. Pixel (0,0) is top-left.
public struct ImageBuffer: Sendable {
    public var width: Int
    public var height: Int
    public var channels: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, channels: Int = 3, value: Float = 0) {
        precondition(width > 0 && height > 0 && channels > 0)
        self.width = width
        self.height = height
        self.channels = channels
        self.pixels = [Float](repeating: value, count: width * height * channels)
    }

    public init(width: Int, height: Int, channels: Int = 3, pixels: [Float]) {
        precondition(pixels.count == width * height * channels)
        self.width = width
        self.height = height
        self.channels = channels
        self.pixels = pixels
    }

    public var count: Int { width * height }

    @inline(__always)
    public func index(_ x: Int, _ y: Int, _ c: Int) -> Int {
        (y * width + x) * channels + c
    }

    @inline(__always)
    public subscript(x: Int, y: Int, c: Int) -> Float {
        get { pixels[index(x, y, c)] }
        set { pixels[index(x, y, c)] = newValue }
    }

    public func pixel(x: Int, y: Int) -> SIMD3<Float> {
        let i = index(x, y, 0)
        return SIMD3(pixels[i], pixels[i + 1], pixels[i + 2])
    }

    public mutating func setPixel(x: Int, y: Int, _ v: SIMD3<Float>) {
        let i = index(x, y, 0)
        pixels[i] = v.x
        pixels[i + 1] = v.y
        pixels[i + 2] = v.z
    }

    public func luminance() -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let j = i * channels
            out[i] = 0.2126 * pixels[j] + 0.7152 * pixels[j + 1] + 0.0722 * pixels[j + 2]
        }
        return out
    }

    public func channel(_ c: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = pixels[i * channels + c] }
        return out
    }

    public mutating func setChannel(_ c: Int, values: [Float]) {
        precondition(values.count == count)
        for i in 0..<count { pixels[i * channels + c] = values[i] }
    }

    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> ImageBuffer {
        precondition(x >= 0 && y >= 0 && x + w <= width && y + h <= height)
        var out = ImageBuffer(width: w, height: h, channels: channels)
        for row in 0..<h {
            let src = ((y + row) * width + x) * channels
            let dst = row * w * channels
            out.pixels.replaceSubrange(dst..<(dst + w * channels), with: pixels[src..<(src + w * channels)])
        }
        return out
    }

    /// Bilinear resize. Used for previews and model input, never for warp.
    public func resized(toWidth nw: Int, toHeight nh: Int) -> ImageBuffer {
        guard nw != width || nh != height else { return self }
        var out = ImageBuffer(width: nw, height: nh, channels: channels)
        let sx = Float(width) / Float(nw)
        let sy = Float(height) / Float(nh)
        for y in 0..<nh {
            let fy = min(max((Float(y) + 0.5) * sy - 0.5, 0), Float(height - 1))
            let y0 = Int(floor(fy)), y1 = min(y0 + 1, height - 1)
            let wy = fy - Float(y0)
            for x in 0..<nw {
                let fx = min(max((Float(x) + 0.5) * sx - 0.5, 0), Float(width - 1))
                let x0 = Int(floor(fx)), x1 = min(x0 + 1, width - 1)
                let wx = fx - Float(x0)
                for c in 0..<channels {
                    let v00 = self[x0, y0, c], v10 = self[x1, y0, c]
                    let v01 = self[x0, y1, c], v11 = self[x1, y1, c]
                    let top = v00 * (1 - wx) + v10 * wx
                    let bot = v01 * (1 - wx) + v11 * wx
                    out[x, y, c] = top * (1 - wy) + bot * wy
                }
            }
        }
        return out
    }

    public func rotated180() -> ImageBuffer {
        var out = ImageBuffer(width: width, height: height, channels: channels)
        for y in 0..<height {
            for x in 0..<width {
                let s = index(width - 1 - x, height - 1 - y, 0)
                let d = out.index(x, y, 0)
                out.pixels[d] = pixels[s]
                out.pixels[d + 1] = pixels[s + 1]
                out.pixels[d + 2] = pixels[s + 2]
            }
        }
        return out
    }

    public func statistics() -> (min: Float, max: Float, mean: Float) {
        var lo: Float = .greatestFiniteMagnitude
        var hi: Float = -.greatestFiniteMagnitude
        var sum: Float = 0
        for v in pixels {
            lo = min(lo, v); hi = max(hi, v); sum += v
        }
        return (lo, hi, sum / Float(pixels.count))
    }

    public func dilated(_ radius: Int) -> ImageBuffer {
        guard radius > 0 else { return self }
        var out = self
        for c in 0..<channels {
            var src = channel(c)
            var tmp = [Float](repeating: 0, count: count)
            for y in 0..<height {
                for x in 0..<width {
                    var m = -Float.greatestFiniteMagnitude
                    for dx in -radius...radius {
                        let xx = min(max(x + dx, 0), width - 1)
                        m = max(m, src[y * width + xx])
                    }
                    tmp[y * width + x] = m
                }
            }
            for y in 0..<height {
                for x in 0..<width {
                    var m = -Float.greatestFiniteMagnitude
                    for dy in -radius...radius {
                        let yy = min(max(y + dy, 0), height - 1)
                        m = max(m, tmp[yy * width + x])
                    }
                    src[y * width + x] = m
                }
            }
            out.setChannel(c, values: src)
        }
        return out
    }
}

/// Simple scalar RGB helpers.
public enum RGBMath {
    @inline(__always)
    public static func clamp(_ v: Float, _ lo: Float = 0, _ hi: Float = 1) -> Float {
        min(max(v, lo), hi)
    }

    public static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var v = values
        v.sort()
        let n = v.count
        return n % 2 == 1 ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2])
    }

    public static func mad(_ values: [Float], median m: Float? = nil) -> Float {
        guard !values.isEmpty else { return 0 }
        let med = m ?? median(values)
        return median(values.map { abs($0 - med) })
    }

    /// Robust per-pixel stack statistics; ignores non-finite values.
    public static func sigmaClip(_ values: [Float], low: Float, high: Float, iterations: Int = 2) -> (mean: Float, count: Int) {
        var v = values.filter { $0.isFinite }
        guard !v.isEmpty else { return (0, 0) }
        for _ in 0..<iterations where v.count > 3 {
            let med = median(v)
            let s = 1.4826 * mad(v, median: med)
            if s <= 1e-9 { break }
            let kept = v.filter { $0 >= med - low * s && $0 <= med + high * s }
            if kept.count == v.count || kept.count < 3 { break }
            v = kept
        }
        var sum: Double = 0
        for x in v { sum += Double(x) }
        return (Float(sum / Double(v.count)), v.count)
    }
}
