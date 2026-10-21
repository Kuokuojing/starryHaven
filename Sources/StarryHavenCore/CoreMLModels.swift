import Foundation
import CoreML

public enum CoreMLModelError: Error, CustomStringConvertible {
    case modelMissing(String)
    case loadFailed(String)
    case predictionFailed(String)
    case unsupportedDescription(String)
    public var description: String {
        switch self {
        case .modelMissing(let s): return "未找到模型：\(s)"
        case .loadFailed(let s): return "模型加载失败：\(s)"
        case .predictionFailed(let s): return "模型推理失败：\(s)"
        case .unsupportedDescription(let s): return "模型输入描述不受支持：\(s)"
        }
    }
}

/// Runs a fixed-size 512x512 RGB CoreML image-to-image model over an arbitrary
/// image, using overlapping tiles and cosine feathering.
public final class TileModelRunner {
    public let model: MLModel
    public let inputName: String
    public let outputName: String
    public let tileSize: Int
    public let backend: String

    public init(packageURL: URL, cacheKey: String) throws {
        let fm = FileManager.default
        let cacheRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = cacheRoot.appendingPathComponent("StarryHaven/Models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let compiledURL = dir.appendingPathComponent("\(cacheKey).mlmodelc")

        let sourceDate = (try? fm.attributesOfItem(atPath: packageURL.path)[.modificationDate] as? Date) ?? Date.distantPast
        let cacheDate = (try? fm.attributesOfItem(atPath: compiledURL.path)[.modificationDate] as? Date) ?? Date.distantPast
        if !fm.fileExists(atPath: compiledURL.path) || cacheDate < sourceDate {
            if fm.fileExists(atPath: compiledURL.path) { try? fm.removeItem(at: compiledURL) }
            let temp = try MLModel.compileModel(at: packageURL)
            try fm.copyItem(at: temp, to: compiledURL)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        config.allowLowPrecisionAccumulationOnGPU = true
        do {
            model = try MLModel(contentsOf: compiledURL, configuration: config)
        } catch {
            throw CoreMLModelError.loadFailed("\(error)")
        }
        guard let input = model.modelDescription.inputDescriptionsByName.first,
              let output = model.modelDescription.outputDescriptionsByName.first else {
            throw CoreMLModelError.unsupportedDescription("no input/output")
        }
        inputName = input.key
        outputName = output.key
        if let constraint = input.value.multiArrayConstraint {
            let shape = constraint.shape.map { $0.intValue }
            tileSize = shape.last ?? 512
        } else {
            tileSize = 512
        }
        #if arch(arm64)
        backend = "CoreML (ANE/GPU/CPU)"
        #else
        backend = "CoreML CPU"
        #endif
    }

    public func predict(tile: ImageBuffer) throws -> ImageBuffer {
        let size = tileSize
        guard tile.width == size, tile.height == size else {
            throw CoreMLModelError.predictionFailed("tile must be \(size)x\(size)")
        }
        let array = try MLMultiArray(shape: [1, 3, size, size] as [NSNumber], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * size * size)
        for c in 0..<3 {
            for y in 0..<size {
                for x in 0..<size {
                    let v = tile.pixels[(y * size + x) * tile.channels + min(c, tile.channels - 1)]
                    ptr[c * size * size + y * size + x] = min(max(v, 0), 1)
                }
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        let result = try model.prediction(from: provider)
        guard let outArray = result.featureValue(for: outputName)?.multiArrayValue else {
            throw CoreMLModelError.predictionFailed("missing output \(outputName)")
        }
        let count = 3 * size * size
        let outPtr = outArray.dataPointer.bindMemory(to: Float.self, capacity: count)
        var out = ImageBuffer(width: size, height: size, channels: 3)
        for c in 0..<3 {
            for y in 0..<size {
                for x in 0..<size {
                    out.pixels[(y * size + x) * 3 + c] = outPtr[c * size * size + y * size + x]
                }
            }
        }
        return out
    }

    public func run(image: ImageBuffer, stride: Int = 256, progress: ((Double) -> Void)? = nil) throws -> ImageBuffer {
        let w = image.width, h = image.height
        let size = tileSize
        var xs: [Int] = [0]
        if w > size {
            var x = stride
            while x + size < w {
                xs.append(x)
                x += stride
            }
            xs.append(w - size)
        }
        xs = Array(Set(xs.map { max(0, min($0, max(0, w - size))) })).sorted()
        var ys: [Int] = [0]
        if h > size {
            var y = stride
            while y + size < h {
                ys.append(y)
                y += stride
            }
            ys.append(h - size)
        }
        ys = Array(Set(ys.map { max(0, min($0, max(0, h - size))) })).sorted()

        var accum = [Double](repeating: 0, count: w * h * 3)
        var weights = [Double](repeating: 0, count: w * h)
        let feather = max(16, min(96, stride / 2))
        let total = Double(xs.count * ys.count)
        var done = 0.0

        for ty in ys {
            for tx in xs {
                var tile = ImageBuffer(width: size, height: size, channels: 3)
                for y in 0..<size {
                    let sy = min(max(ty + y, 0), h - 1)
                    for x in 0..<size {
                        let sx = min(max(tx + x, 0), w - 1)
                        let si = (sy * w + sx) * image.channels
                        let di = (y * size + x) * 3
                        tile.pixels[di] = image.pixels[si]
                        tile.pixels[di + 1] = image.pixels[si + 1]
                        tile.pixels[di + 2] = image.pixels[si + 2]
                    }
                }
                let out = try predict(tile: tile)
                for y in 0..<size {
                    let oy = ty + y
                    if oy < 0 || oy >= h { continue }
                    var wy = 1.0
                    if ys.count > 1 {
                        let edgeTop = ty > 0
                        let edgeBottom = ty + size < h
                        if edgeTop && y < feather {
                            wy = 0.5 - 0.5 * cos(Double.pi * (Double(y) + 0.5) / Double(feather))
                        }
                        if edgeBottom && y >= size - feather {
                            let k = Double(size - 1 - y)
                            wy = min(wy, 0.5 - 0.5 * cos(Double.pi * (k + 0.5) / Double(feather)))
                        }
                    }
                    for x in 0..<size {
                        let ox = tx + x
                        if ox < 0 || ox >= w { continue }
                        var wx = 1.0
                        if xs.count > 1 {
                            let edgeLeft = tx > 0
                            let edgeRight = tx + size < w
                            if edgeLeft && x < feather {
                                wx = 0.5 - 0.5 * cos(Double.pi * (Double(x) + 0.5) / Double(feather))
                            }
                            if edgeRight && x >= size - feather {
                                let k = Double(size - 1 - x)
                                wx = min(wx, 0.5 - 0.5 * cos(Double.pi * (k + 0.5) / Double(feather)))
                            }
                        }
                        let weight = max(wx * wy, 1e-6)
                        let di = (y * size + x) * 3
                        let oi = oy * w + ox
                        accum[oi * 3] += Double(out.pixels[di]) * weight
                        accum[oi * 3 + 1] += Double(out.pixels[di + 1]) * weight
                        accum[oi * 3 + 2] += Double(out.pixels[di + 2]) * weight
                        weights[oi] += weight
                    }
                }
                done += 1
                progress?(done / total)
            }
        }
        var result = ImageBuffer(width: w, height: h, channels: 3)
        for i in 0..<(w * h) {
            let wgt = max(weights[i], 1e-9)
            for c in 0..<3 {
                result.pixels[i * 3 + c] = Float(accum[i * 3 + c] / wgt)
            }
        }
        return result
    }
}

public enum StarSeparation {
    public struct Result: Sendable {
        public var starless: ImageBuffer
        public var stars: ImageBuffer
        public var mask: [Float]
        public var backend: String
    }

    public static func separate(image: ImageBuffer, stride: Int = 256, progress: ((Double) -> Void)? = nil) throws -> Result {
        guard let url = ModelLocator.starNet2 else { throw CoreMLModelError.modelMissing("StarNet2_weights.mlpackage") }
        let runner = try TileModelRunner(packageURL: url, cacheKey: "StarNet2")
        let starless = try runner.run(image: image, stride: stride, progress: progress)
        var stars = ImageBuffer(width: image.width, height: image.height, channels: 3)
        var mask = [Float](repeating: 0, count: image.count)
        for i in 0..<image.count {
            for c in 0..<3 {
                // Signed residual so recomposition is exact; the saved star
                // layer clamps negative values to black.
                stars.pixels[i * 3 + c] = image.pixels[i * image.channels + min(c, image.channels - 1)] - starless.pixels[i * 3 + c]
            }
            mask[i] = max(0, 0.2126 * stars.pixels[i * 3] + 0.7152 * stars.pixels[i * 3 + 1] + 0.0722 * stars.pixels[i * 3 + 2])
        }
        let maxMask = mask.max() ?? 1
        if maxMask > 0 {
            for i in 0..<mask.count { mask[i] /= maxMask }
        }
        let artifact = ModelLocator.artifactDescription(url)
        return Result(starless: starless, stars: stars, mask: mask, backend: "StarNet2 · \(runner.backend) · \(artifact)")
    }

    public static func recompose(starless: ImageBuffer, stars: ImageBuffer, amount: Double = 1.0) -> ImageBuffer {
        var out = starless
        for i in 0..<min(out.pixels.count, stars.pixels.count) {
            out.pixels[i] = max(0, min(1, out.pixels[i] + stars.pixels[i] * Float(amount)))
        }
        return out
    }

    public static func softStretchStars(stars: ImageBuffer, radius: Double = 1.5, amount: Double = 0.5) -> ImageBuffer {
        // A simple bloom: blend a blurred copy of the star layer back into it.
        let w = stars.width, h = stars.height
        var blurred = ImageBuffer(width: w, height: h, channels: 3)
        let r = max(1, Int(radius.rounded()))
        for c in 0..<3 {
            for y in 0..<h {
                for x in 0..<w {
                    var sum: Float = 0
                    var n: Float = 0
                    for dy in -r...r {
                        let yy = min(max(y + dy, 0), h - 1)
                        for dx in -r...r {
                            let xx = min(max(x + dx, 0), w - 1)
                            sum += stars.pixels[(yy * w + xx) * 3 + c]
                            n += 1
                        }
                    }
                    blurred.pixels[(y * w + x) * 3 + c] = sum / n
                }
            }
        }
        var out = stars
        for i in 0..<out.pixels.count {
            out.pixels[i] = stars.pixels[i] * Float(1 - amount) + blurred.pixels[i] * Float(amount)
        }
        return out
    }
}

public enum DeepSNR {
    public static var isAvailable: Bool { ModelLocator.deepSNR != nil }

    public static func denoise(image: ImageBuffer, stride: Int = 256, progress: ((Double) -> Void)? = nil) throws -> ImageBuffer {
        guard let url = ModelLocator.deepSNR else { throw CoreMLModelError.modelMissing("DeepSNR_weights_v2.mlpackage") }
        let runner = try TileModelRunner(packageURL: url, cacheKey: "DeepSNR")
        return try runner.run(image: image, stride: stride, progress: progress)
    }

    public static func describe() -> String {
        guard let url = ModelLocator.deepSNR else { return "DeepSNR model missing" }
        do {
            let runner = try TileModelRunner(packageURL: url, cacheKey: "DeepSNR")
            return "DeepSNR · \(runner.backend) · tile \(runner.tileSize)"
        } catch {
            return "DeepSNR load error: \(error)"
        }
    }
}

public enum StarNetInfo {
    public static func describe() -> String {
        guard let url = ModelLocator.starNet2 else { return "StarNet2 model missing" }
        do {
            let runner = try TileModelRunner(packageURL: url, cacheKey: "StarNet2")
            return "StarNet2 · \(runner.backend) · tile \(runner.tileSize)"
        } catch {
            return "StarNet2 load error: \(error)"
        }
    }
}
