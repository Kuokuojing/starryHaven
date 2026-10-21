import Foundation
import ImageIO
import StarryHavenCore

enum SelfTest {
    static func run(outputDirectory out: URL) throws -> Bool {
        let fm = FileManager.default
        let inputDir = out.appendingPathComponent("input", isDirectory: true)
        let run1 = out.appendingPathComponent("run-1", isDirectory: true)
        let run2 = out.appendingPathComponent("run-2", isDirectory: true)
        for dir in [inputDir, run1, run2] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let w = 512, h = 512
        let stars = SyntheticScene.randomStars(width: w, height: h, count: 45, seed: 2026,
                                               minSeparation: 14, sigmaRange: 1.4...2.0)
        let base = SyntheticScene.starField(width: w, height: h, stars: stars, background: 0.02,
                                            backgroundGradient: 0.006, noise: 0, seed: 1)
        var files: [URL] = []
        let transforms: [Matrix3] = (0..<8).map { i in
            let a = Double(i) * 0.06
            return Matrix3([cos(a), -sin(a), Double(i * 3 - 10),
                            sin(a), cos(a), Double((i % 3) * 2 - 2),
                            0, 0, 1])
        }
        for (i, g) in transforms.enumerated() {
            var frame = Warp.warp(base, imageToReference: g, outputWidth: w, outputHeight: h)!.image
            var rng = SyntheticScene.Random(seed: UInt64(1000 + i))
            for j in 0..<frame.pixels.count {
                frame.pixels[j] = max(0, frame.pixels[j] + Float(rng.gaussian() * 0.004))
            }
            let url = inputDir.appendingPathComponent(String(format: "frame-%02d.tif", i))
            try ImageWriter.save(frame, url: url, format: .tiff16)
            files.append(url)
        }

        func runPipeline(to dir: URL) throws -> StackPipelineResult {
            var request = StackRequest()
            request.lights = files
            request.referenceIndex = 0
            request.method = .sigmaClipped
            request.lowSigma = 4
            request.highSigma = 5
            request.outputURL = dir.appendingPathComponent("stack.tif")
            request.outputFormat = .tiff16
            return try StackPipeline.run(request) { p, msg in
                print(String(format: "[%3.0f%%] %@", p * 100, msg))
            }
        }

        print("=== run 1")
        let r1 = try runPipeline(to: run1)
        print("=== run 2")
        let r2 = try runPipeline(to: run2)

        func metrics(_ result: StackPipelineResult, output: URL) throws -> [String: Double] {
            let stack = try ImageLoader.load(url: output)
            let first = try ImageLoader.load(url: files[0])
            let stackField = StarDetector.detect(image: stack)
            let firstField = StarDetector.detect(image: first)
            let fwhmStack = stackField.stars.prefix(25).map { $0.fwhm }.sorted()
            let fwhmFirst = firstField.stars.prefix(25).map { $0.fwhm }.sorted()
            let stackMedian = fwhmStack.isEmpty ? 0 : fwhmStack[fwhmStack.count / 2]
            let firstMedian = fwhmFirst.isEmpty ? 0 : fwhmFirst[fwhmFirst.count / 2]

            // Minimum-noise 48x48 background window: star residuals cannot
            // inflate the estimate because a star-free window always exists.
            func residualNoise(_ img: ImageBuffer) -> Double {
                var best = Double.greatestFiniteMagnitude
                let win = 48
                for wy in stride(from: 8, to: h - win - 8, by: 24) {
                    for wx in stride(from: 8, to: w - win - 8, by: 24) {
                        var sum = 0.0, sum2 = 0.0, n = 0.0
                        for y in wy..<(wy + win) {
                            for x in wx..<(wx + win) {
                                let r = Double(img[x, y, 0] - base[x, y, 0])
                                sum += r; sum2 += r * r; n += 1
                            }
                        }
                        let mean = sum / n
                        let sd = sqrt(max(sum2 / n - mean * mean, 0))
                        best = min(best, sd)
                    }
                }
                return best.isFinite ? best : 0
            }
            let noiseStack = residualNoise(stack)
            let noiseFirst = residualNoise(first)
            let result: [String: Double] = [
                "width": Double(stack.width),
                "height": Double(stack.height),
                "fwhmInput": firstMedian,
                "fwhmStack": stackMedian,
                "noiseSingle": noiseFirst,
                "noiseStack": noiseStack,
                "detectedStars": Double(stackField.stars.count),
                "usedFrames": Double(result.usedFrames),
                "registrationRMS": result.registration.values.map { $0.rms }.max() ?? 0,
                "cropX": Double(result.cropRect.minX),
                "cropY": Double(result.cropRect.minY),
            ]
            return result
        }

        let m1 = try metrics(r1, output: run1.appendingPathComponent("stack.tif"))
        let m2 = try metrics(r2, output: run2.appendingPathComponent("stack.tif"))
        var checks: [String: Bool] = [:]
        checks["dims"] = m1["width"] == 512 && m1["height"] == 512
        checks["fwhm"] = (m1["fwhmStack"] ?? 9) <= (m1["fwhmInput"] ?? 0) + 0.2
        checks["noise"] = (m1["noiseStack"] ?? 9) < (m1["noiseSingle"] ?? 0)
        checks["runConsistency"] = {
            for key in ["fwhmStack", "noiseStack", "registrationRMS"] {
                let a = m1[key] ?? 0, b = m2[key] ?? 0
                let denom = max(abs(a), abs(b), 1e-9)
                if abs(a - b) / denom > 0.05 { return false }
            }
            return true
        }()

        let bits = tiffBitsPerSample(run1.appendingPathComponent("stack.tif"))
        checks["tiff16"] = bits == 16

        func deltaPct(_ key: String) -> Double {
            let a = m1[key] ?? 0, b = m2[key] ?? 0
            let denom = max(abs(a), abs(b), 1e-9)
            return abs(a - b) / denom * 100
        }
        let comparison: [String: Double] = [
            "fwhmDeltaPct": deltaPct("fwhmStack"),
            "noiseDeltaPct": deltaPct("noiseStack"),
            "registrationRMSDeltaPct": deltaPct("registrationRMS"),
            "starCountDeltaPct": deltaPct("detectedStars"),
            "maxDeltaPct": ["fwhmStack", "noiseStack", "registrationRMS", "detectedStars"].map(deltaPct).max() ?? 0,
        ]
        print(String(format: "RUN DIFF max %.4f%% (fwhm %.4f%%, noise %.4f%%, rms %.4f%%)",
                     comparison["maxDeltaPct"] ?? 0, comparison["fwhmDeltaPct"] ?? 0,
                     comparison["noiseDeltaPct"] ?? 0, comparison["registrationRMSDeltaPct"] ?? 0))
        let summary: [String: Any] = [
            "run1": m1,
            "run2": m2,
            "runDirectories": [run1.path, run2.path],
            "runComparison": comparison,
            "checks": checks,
            "tiffBitsPerSample": bits,
            "modelInfo": ModelLocator.statusDescription,
            "log1": r1.log,
            "log2": r2.log,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        let jsonURL = out.appendingPathComponent("selftest.json")
        try data.write(to: jsonURL)
        print(String(data: data, encoding: .utf8) ?? "{}")
        let ok = checks.values.allSatisfy { $0 }
        print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        return ok
    }

    static func tiffBitsPerSample(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return 0
        }
        if let depth = props[kCGImagePropertyDepth] as? Int { return depth }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let bits = tiff["BitsPerSample" as CFString] as? Int { return bits }
        return 0
    }
}
