import Foundation
import COnnxRuntime

public struct SkyMask: Sendable {
    public var mask: [Float]
    public var width: Int
    public var height: Int

    public init(mask: [Float], width: Int, height: Int) {
        self.mask = mask; self.width = width; self.height = height
    }

    public func value(x: Int, y: Int) -> Float { mask[y * width + x] }

    public func upsampled(toWidth w: Int, toHeight h: Int) -> SkyMask {
        guard w != width || h != height else { return self }
        var out = [Float](repeating: 0, count: w * h)
        let sx = Double(width) / Double(w)
        let sy = Double(height) / Double(h)
        for y in 0..<h {
            let fy = min(max((Double(y) + 0.5) * sy - 0.5, 0), Double(height - 1))
            let y0 = Int(floor(fy)), y1 = min(y0 + 1, height - 1)
            let wy = fy - Double(y0)
            for x in 0..<w {
                let fx = min(max((Double(x) + 0.5) * sx - 0.5, 0), Double(width - 1))
                let x0 = Int(floor(fx)), x1 = min(x0 + 1, width - 1)
                let wx = fx - Double(x0)
                let v00 = Double(self.mask[y0 * width + x0]), v10 = Double(self.mask[y0 * width + x1])
                let v01 = Double(self.mask[y1 * width + x0]), v11 = Double(self.mask[y1 * width + x1])
                let top = v00 * (1 - wx) + v10 * wx
                let bot = v01 * (1 - wx) + v11 * wx
                out[y * w + x] = Float(top * (1 - wy) + bot * wy)
            }
        }
        return SkyMask(mask: out, width: w, height: h)
    }

    /// Conservative erosion: a pixel is sky only if its whole neighbourhood is
    /// sky. Keeps learned-mask boundary uncertainty from touching the ground.
    public func eroded(by radius: Int) -> SkyMask {
        guard radius > 0 else { return self }
        var out = [Float](repeating: 0, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width - 1, x + radius)
                let y0 = max(0, y - radius), y1 = min(height - 1, y + radius)
                var m: Float = 1
                for yy in y0...y1 {
                    for xx in x0...x1 { m = min(m, mask[yy * width + xx]) }
                }
                out[y * width + x] = m
            }
        }
        return SkyMask(mask: out, width: width, height: height)
    }

    /// Intersection over union against a binary ground-truth mask.
    public func iou(against ground: [Float], threshold: Float = 0.5) -> Double {
        guard ground.count == mask.count else { return 0 }
        var intersection = 0.0, union = 0.0
        for i in 0..<mask.count {
            let a = mask[i] >= threshold
            let b = ground[i] >= 0.5
            if a && b { intersection += 1 }
            if a || b { union += 1 }
        }
        return union > 0 ? intersection / union : 1
    }
}

public enum SkySegError: Error, CustomStringConvertible {
    case modelMissing
    case runtimeMissing
    case inference(String)
    case invalidModel
    public var description: String {
        switch self {
        case .modelMissing: return "未找到 SkySeg 模型 (skyseg.onnx)"
        case .runtimeMissing: return "未找到 ONNX Runtime 动态库"
        case .inference(let s): return "SkySeg 推理失败：\(s)"
        case .invalidModel: return "SkySeg 模型输入尺寸不受支持"
        }
    }
}

public enum SkySegmenter {
    public static let inputSize = 320

    private static func configureRuntime() {
        if let runtime = ModelLocator.onnxRuntime {
            setenv("ONNXRUNTIME_LIB", runtime.path, 1)
        }
    }

    public static var isAvailable: Bool {
        configureRuntime()
        return ModelLocator.skySeg != nil && sf_ort_available() != 0
    }

    public static var artifactDescription: String {
        "SkySeg ONNX · " + ModelLocator.artifactDescription(ModelLocator.skySeg)
    }

    public static func describeModel() -> String {
        configureRuntime()
        guard let url = ModelLocator.skySeg else { return "SkySeg model missing" }
        var buffer = [CChar](repeating: 0, count: 4096)
        let status = sf_ort_describe(url.path, &buffer, buffer.count)
        if status != 0 { return "SkySeg describe failed (\(status)): \(String(cString: buffer))" }
        return String(cString: buffer)
    }

    /// Runs the real SkySeg ONNX model (320x320, RGB, 0...1). The model's first
    /// output is the final sky mask (1 = sky, 0 = ground); it is upsampled to
    /// the input image size.
    public static func segment(image: ImageBuffer, modelURL: URL? = nil, outputIndex: Int = 0) throws -> SkyMask {
        configureRuntime()
        guard let url = modelURL ?? ModelLocator.skySeg else { throw SkySegError.modelMissing }
        let size = inputSize
        var resized = image.resized(toWidth: size, toHeight: size)
        if resized.channels != 3 {
            var rgb = ImageBuffer(width: size, height: size, channels: 3)
            for i in 0..<(size * size) {
                for c in 0..<3 { rgb.pixels[i * 3 + c] = resized.pixels[i * resized.channels + min(c, resized.channels - 1)] }
            }
            resized = rgb
        }
        var input = [Float](repeating: 0, count: 3 * size * size)
        for y in 0..<size {
            for x in 0..<size {
                for c in 0..<3 {
                    input[c * size * size + y * size + x] = resized[x, y, c]
                }
            }
        }
        var out = [Float](repeating: 0, count: size * size)
        var ow: Int32 = 0
        var oh: Int32 = 0
        var error = [CChar](repeating: 0, count: 1024)
        let status: Int32 = input.withUnsafeBufferPointer { inPtr in
            out.withUnsafeMutableBufferPointer { outPtr in
                error.withUnsafeMutableBufferPointer { errPtr in
                    sf_ort_skyseg_run(url.path, inPtr.baseAddress, Int32(size), Int32(size), Int32(outputIndex),
                                      outPtr.baseAddress, &ow, &oh, errPtr.baseAddress, errPtr.count)
                }
            }
        }
        guard status == 0 else {
            throw SkySegError.inference(String(cString: error))
        }
        let maskW = Int(ow), maskH = Int(oh)
        guard maskW > 0, maskH > 0, out.count >= maskW * maskH else { throw SkySegError.inference("空输出") }
        let mask = SkyMask(mask: Array(out.prefix(maskW * maskH)), width: maskW, height: maskH)
        return mask.upsampled(toWidth: image.width, toHeight: image.height)
    }

    /// Forces model weights to load once and reports the backend.
    public static func warmUp() throws {
        guard isAvailable else { throw SkySegError.runtimeMissing }
        let probe = ImageBuffer(width: 64, height: 64, channels: 3, value: 0.5)
        _ = try segment(image: probe)
    }
}

public enum SkyComposite {
    /// Applies `effect` only where mask == sky. Ground pixels are copied bit-exactly.
    public static func skyOnly(original: ImageBuffer, effect: ImageBuffer, mask: SkyMask) -> ImageBuffer {
        var out = original
        let source = mask.width == original.width && mask.height == original.height
            ? mask
            : mask.upsampled(toWidth: original.width, toHeight: original.height)
        // Erode by two pixels and use a hard sky decision: learned-mask values
        // straddling 0.5 on the horizon must never perturb a ground pixel.
        let m = source.eroded(by: 2).mask
        for i in 0..<original.count {
            guard m[i] >= 0.5 else { continue }
            for c in 0..<min(3, original.channels) {
                out.pixels[i * original.channels + c] = effect.pixels[i * original.channels + c]
            }
        }
        return out
    }

    public static func applyMask(_ mask: SkyMask, to image: ImageBuffer, groundValue: Float? = nil) -> ImageBuffer {
        var out = image
        for i in 0..<image.count {
            if mask.mask[i] < 0.5 {
                if let g = groundValue {
                    for c in 0..<3 { out.pixels[i * 3 + c] = g }
                }
            }
        }
        return out
    }

    /// Builds a manual mask from a black/white image (luminance >= 0.5 = sky).
    public static func manualMask(image: ImageBuffer) -> SkyMask {
        let lum = image.luminance()
        var mask = [Float](repeating: 0, count: lum.count)
        for i in 0..<lum.count { mask[i] = lum[i] >= 0.5 ? 1 : 0 }
        return SkyMask(mask: mask, width: image.width, height: image.height)
    }
}
