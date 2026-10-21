import Foundation

public struct LensCorrectionOptions: Sendable {
    /// 0 = off, 1 = strongly brighten the corners.
    public var vignette: Double = 0
    /// -1 = pincushion-style, +1 = barrel-style radial remap.
    public var distortion: Double = 0
    public init() {}
}

public enum LensCorrection {
    public static func apply(_ image: ImageBuffer, options: LensCorrectionOptions) -> ImageBuffer {
        guard abs(options.vignette) > 1e-6 || abs(options.distortion) > 1e-6 else { return image }
        let w = image.width, h = image.height
        let cx = Double(w - 1) * 0.5, cy = Double(h - 1) * 0.5
        let maxR2 = cx * cx + cy * cy
        var source = image
        if abs(options.distortion) > 1e-6 {
            var remapped = ImageBuffer(width: w, height: h, channels: image.channels)
            let k = options.distortion * 0.25
            for y in 0..<h {
                for x in 0..<w {
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    let r2 = (dx * dx + dy * dy) / max(maxR2, 1)
                    let scale = 1 + k * r2
                    let sx = cx + dx * scale, sy = cy + dy * scale
                    if sx < 0 || sy < 0 || sx > Double(w - 1) || sy > Double(h - 1) { continue }
                    let x0 = Int(floor(sx)), y0 = Int(floor(sy))
                    let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                    let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                    for c in 0..<image.channels {
                        let v00 = image[x0, y0, c], v10 = image[x1, y0, c]
                        let v01 = image[x0, y1, c], v11 = image[x1, y1, c]
                        let top = v00 * (1 - fx) + v10 * fx
                        let bot = v01 * (1 - fx) + v11 * fx
                        remapped[x, y, c] = top * (1 - fy) + bot * fy
                    }
                }
            }
            source = remapped
        }
        if abs(options.vignette) > 1e-6 {
            var out = source
            for y in 0..<h {
                for x in 0..<w {
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    let r2 = (dx * dx + dy * dy) / max(maxR2, 1)
                    let gain = Float(1 + options.vignette * r2)
                    for c in 0..<out.channels { out[x, y, c] = max(0, out[x, y, c] * gain) }
                }
            }
            return out
        }
        return source
    }
}
