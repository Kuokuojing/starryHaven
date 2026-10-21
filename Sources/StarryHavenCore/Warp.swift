import Foundation

public struct WarpResult: Sendable {
    public var image: ImageBuffer
    public var coverage: [Float]
}

public enum Warp {
    /// Warps `image` into the reference frame. `imageToReference` maps image pixel
    /// coordinates to reference pixel coordinates. Output has the reference size.
    public static func warp(_ image: ImageBuffer,
                            imageToReference: Matrix3,
                            outputWidth: Int,
                            outputHeight: Int,
                            lanczosA: Int = 3) -> WarpResult? {
        warpRegion(image,
                   imageToReference: imageToReference,
                   region: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
                   fullWidth: outputWidth,
                   fullHeight: outputHeight,
                   lanczosA: lanczosA)
    }

    /// Warps only `region` of the reference frame. Coordinates in `region` are
    /// absolute reference pixels; the returned buffer is region-sized.
    public static func warpRegion(_ image: ImageBuffer,
                                  imageToReference: Matrix3,
                                  region: CGRect,
                                  fullWidth: Int,
                                  fullHeight: Int,
                                  lanczosA: Int = 3) -> WarpResult? {
        guard let inverse = imageToReference.inverse else { return nil }
        let originX = Int(region.minX.rounded())
        let originY = Int(region.minY.rounded())
        let outputWidth = Int(region.width.rounded())
        let outputHeight = Int(region.height.rounded())
        guard outputWidth > 0, outputHeight > 0 else { return nil }
        var coverage = [Float](repeating: 0, count: outputWidth * outputHeight)
        let a = max(2, min(lanczosA, 4))
        let taps = 2 * a
        let sw = image.width, sh = image.height
        let channels = image.channels

        let rows = outputHeight
        var temp = ImageBuffer(width: outputWidth, height: outputHeight, channels: 3)

        temp.pixels.withUnsafeMutableBufferPointer { outPtr in
            image.pixels.withUnsafeBufferPointer { srcPtr in
                coverage.withUnsafeMutableBufferPointer { covPtr in
                    DispatchQueue.concurrentPerform(iterations: rows) { oy in
                        let wy = Double(oy + originY)
                        for ox in 0..<outputWidth {
                            let wxOut = Double(ox + originX)
                            let sx = inverse.m[0] * wxOut + inverse.m[1] * wy + inverse.m[2]
                            let sy = inverse.m[3] * wxOut + inverse.m[4] * wy + inverse.m[5]
                            let wden = inverse.m[6] * wxOut + inverse.m[7] * wy + inverse.m[8]
                            let fx = wden == 0 ? sx : sx / wden
                            let fy = wden == 0 ? sy : sy / wden
                            let oi = oy * outputWidth + ox
                            if !fx.isFinite || !fy.isFinite || fx < 0 || fy < 0 || fx > Double(sw - 1) || fy > Double(sh - 1) {
                                continue
                            }
                            let ix = Int(floor(fx)), iy = Int(floor(fy))
                            var sum0 = 0.0, sum1 = 0.0, sum2 = 0.0, wsum = 0.0
                            for j in 0..<taps {
                                let yy = iy + j - a + 1
                                if yy < 0 || yy >= sh { continue }
                                let wyv = lanczos(fy - Double(yy), a: a)
                                if wyv == 0 { continue }
                                let srcRow = yy * sw * channels
                                for i in 0..<taps {
                                    let xx = ix + i - a + 1
                                    if xx < 0 || xx >= sw { continue }
                                    let wx = lanczos(fx - Double(xx), a: a)
                                    let w = wx * wyv
                                    if w == 0 { continue }
                                    let si = srcRow + xx * channels
                                    sum0 += Double(srcPtr[si]) * w
                                    sum1 += Double(srcPtr[si + 1]) * w
                                    sum2 += Double(srcPtr[si + 2]) * w
                                    wsum += w
                                }
                            }
                            if abs(wsum) > 1e-9 {
                                let d = oi * 3
                                outPtr[d] = Float(sum0 / wsum)
                                outPtr[d + 1] = Float(sum1 / wsum)
                                outPtr[d + 2] = Float(sum2 / wsum)
                            }
                            // Coverage feathers over 2 px at the source border.
                            let edge = min(min(fx, Double(sw - 1) - fx), min(fy, Double(sh - 1) - fy))
                            covPtr[oi] = Float(min(max(edge / 2.0, 0), 1))
                        }
                    }
                }
            }
        }
        return WarpResult(image: temp, coverage: coverage)
    }

    @inline(__always)
    public static func lanczos(_ x: Double, a: Int = 3) -> Double {
        let ax = abs(x)
        if ax < 1e-9 { return 1 }
        if ax >= Double(a) { return 0 }
        let px = Double.pi * x
        return Double(a) * sin(px) * sin(px / Double(a)) / (px * px)
    }

    /// Axis-aligned bounding box of the reference frame covered by an image frame.
    public static func transformedBounds(width: Int, height: Int, imageToReference: Matrix3) -> CGRect {
        let corners = [(0.0, 0.0), (Double(width), 0.0), (0.0, Double(height)), (Double(width), Double(height))]
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for c in corners {
            let p = imageToReference.apply(c.0, c.1)
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
