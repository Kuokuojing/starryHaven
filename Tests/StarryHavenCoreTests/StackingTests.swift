import Foundation
import Testing
@testable import StarryHavenCore

@Suite("Calibration, stacking and crop")
struct StackingTests {
    func makeCalibrationScene() -> (base: ImageBuffer, bias: ImageBuffer, dark: ImageBuffer, flat: ImageBuffer, light: ImageBuffer) {
        let w = 192, h = 128
        let stars = SyntheticScene.randomStars(width: w, height: h, count: 25, seed: 21, minSeparation: 12)
        let base = SyntheticScene.starField(width: w, height: h, stars: stars, background: 0.04,
                                            backgroundGradient: 0.02, noise: 0, seed: 1)
        var bias = ImageBuffer(width: w, height: h, channels: 3)
        var dark = ImageBuffer(width: w, height: h, channels: 3)
        var flat = ImageBuffer(width: w, height: h, channels: 3)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    bias[x, y, c] = Float(0.02 + 0.00008 * Double(x) + 0.00004 * Double(y) + 0.001 * Double(c))
                    dark[x, y, c] = Float(0.008 + 0.00003 * Double(x + y) + 0.0004 * Double(c))
                    flat[x, y, c] = Float(1.0 + 0.10 * (Double(x) / Double(w) - 0.5) + 0.07 * (Double(y) / Double(h) - 0.5))
                }
            }
        }
        var light = ImageBuffer(width: w, height: h, channels: 3)
        for i in 0..<light.pixels.count {
            light.pixels[i] = base.pixels[i] * flat.pixels[i] + bias.pixels[i] + dark.pixels[i]
        }
        return (base, bias, dark, flat, light)
    }

    @Test func calibrationMatchesAnalyticFormula() throws {
        let scene = makeCalibrationScene()
        let biasMaster = try #require(Calibration.master(frames: Array(repeating: scene.bias, count: 3)))
        let darkMaster = try #require(Calibration.master(frames: Array(repeating: scene.dark, count: 4)))
        let flatMaster = try #require(Calibration.flatMaster(frames: Array(repeating: scene.flat, count: 3), bias: nil, dark: nil))
        var options = CalibrationOptions()
        options.badPixelCorrection = false
        let calibrated = Calibration.calibrate(light: scene.light,
                                              masters: CalibrationMasters(bias: biasMaster, dark: darkMaster, flat: flatMaster),
                                              options: options)
        var maxError = 0.0
        for i in 0..<calibrated.pixels.count {
            let expected = (scene.light.pixels[i] - scene.bias.pixels[i] - scene.dark.pixels[i]) / scene.flat.pixels[i]
            maxError = max(maxError, abs(Double(calibrated.pixels[i] - expected)))
        }
        print(String(format: "calibration max error %.6g", maxError))
        TestEvidence.write(String(format: "calibration max error: %.8f", maxError), name: "calibration.log")
        #expect(maxError < 1e-3)
    }

    @Test func badPixelCorrectionFixesHotPixels() throws {
        var scene = makeCalibrationScene()
        let w = scene.dark.width, h = scene.dark.height
        var mask = [Float](repeating: 0, count: w * h)
        for (x, y) in [(20, 20), (55, 40), (90, 70), (140, 100), (170, 30)] {
            for c in 0..<3 { scene.dark[x, y, c] += 0.8 }
            mask[y * w + x] = 1
        }
        var options = CalibrationOptions()
        options.badPixelCorrection = true
        let masters = CalibrationMasters(bias: scene.bias, dark: scene.dark, flat: scene.flat, badPixels: mask)
        let calibrated = Calibration.calibrate(light: scene.light, masters: masters, options: options)
        var worst = 0.0
        for (x, y) in [(20, 20), (55, 40), (90, 70), (140, 100), (170, 30)] {
            worst = max(worst, abs(Double(calibrated[x, y, 0] - scene.base[x, y, 0])))
        }
        for c in 0..<3 {
            worst = max(worst, abs(Double(calibrated[20, 20, c] - scene.base[20, 20, c])))
        }
        print(String(format: "bad-pixel worst residual %.4f", worst))
        #expect(worst < 0.08)
    }

    @Test func stackMethodsReduceNoiseAndHandleSatelliteTrail() throws {
        let w = 384, h = 256
        let stars = SyntheticScene.randomStars(width: w, height: h, count: 45, seed: 31, minSeparation: 14)
        let base = SyntheticScene.starField(width: w, height: h, stars: stars, background: 0.05, noise: 0, seed: 2)
        var frames: [ImageBuffer] = []
        var rng = SyntheticScene.Random(seed: 77)
        for _ in 0..<12 {
            var f = ImageBuffer(width: w, height: h, channels: 3)
            for i in 0..<f.pixels.count {
                f.pixels[i] = max(0, base.pixels[i] + Float(rng.gaussian() * 0.01))
            }
            frames.append(f)
        }
        SyntheticScene.addSatelliteTrail(to: &frames[4], from: (20, 40), to: (360, 210), brightness: 0.45, width: 1.1)
        let trailPoint = (x: 200, y: 130)
        // Noise is isolated by subtracting the known noise-free scene, so star
        // wings and gradients cannot inflate the background estimate.
        func residualNoise(_ image: ImageBuffer) -> Double {
            var residual = image
            for i in 0..<residual.pixels.count { residual.pixels[i] -= base.pixels[i] }
            return backgroundNoise(residual, region: (x: 260, y: 10, w: 100, h: 60))
        }
        let singleNoise = residualNoise(frames[0])

        func run(_ method: StackMethod) throws -> StackResult {
            var o = StackOptions(); o.method = method
            return try Stacker.stack(frames: frames.map { StackFrame(image: $0, transform: .identity) },
                                     fullWidth: w, fullHeight: h, options: o)
        }
        let mean = try run(.mean)
        let median = try run(.median)
        let sigma = try run(.sigmaClipped)
        let maximum = try run(.maximum)
        let minimum = try run(.minimum)

        // Direct reference mean at one pixel, to catch stacking mistakes.
        var manual = ImageBuffer(width: w, height: h, channels: 3)
        for i in 0..<manual.pixels.count {
            var s: Double = 0
            for f in frames { s += Double(f.pixels[i]) }
            manual.pixels[i] = Float(s / Double(frames.count))
        }
        let manualDiff = meanDifference(manual, mean.image)
        print(String(format: "manual mean vs stack mean: mean abs diff %.3g, max diff %.3g, manual noise %.5f",
                     manualDiff, maxDifference(manual, mean.image),
                     backgroundNoise(manual, region: (x: 280, y: 20, w: 80, h: 60))))

        let meanNoise = residualNoise(mean.image)
        let medianNoise = residualNoise(median.image)
        print(String(format: "single noise %.5f, mean %.5f (%.2fx), median %.5f (%.2fx)",
                     singleNoise, meanNoise, meanNoise / singleNoise, medianNoise, medianNoise / singleNoise))
        #expect(meanNoise <= 0.7 * singleNoise)
        #expect(medianNoise <= 0.7 * singleNoise)

        let sigmaTrail = sigma.image[trailPoint.x, trailPoint.y, 0]
        let maxTrail = maximum.image[trailPoint.x, trailPoint.y, 0]
        let baseTrail = base[trailPoint.x, trailPoint.y, 0]
        let meanTrail = mean.image[trailPoint.x, trailPoint.y, 0]
        print("trail value base \(baseTrail) sigma \(sigmaTrail) max \(maxTrail) mean \(meanTrail)")
        #expect(abs(Double(sigmaTrail - baseTrail)) < 0.05)
        #expect(maxTrail > baseTrail + 0.2)
        #expect(maxTrail > sigmaTrail + 0.2)
        #expect(minimum.image[trailPoint.x, trailPoint.y, 0] < meanTrail)

        TestEvidence.write(String(format: """
        single-frame noise: %.5f
        mean noise: %.5f (%.3fx)
        median noise: %.5f (%.3fx)
        trail base: %.4f sigma: %.4f max: %.4f
        """, singleNoise, meanNoise, meanNoise / singleNoise, medianNoise, medianNoise / singleNoise,
                            baseTrail, sigmaTrail, maxTrail), name: "stack.log")
        TestEvidence.save(sigma.image, name: "stack-sigma.png")
        TestEvidence.save(maximum.image, name: "stack-maximum.png")
        TestEvidence.save(sigma.image, name: "stack-sigma.tif", format: .tiff16)
        TestEvidence.save(maximum.image, name: "stack-maximum.fits", format: .fits32)
    }

    @Test func cropToOverlapMatchesKnownIntersection() throws {
        let w = 200, h = 150
        let stars = SyntheticScene.randomStars(width: w, height: h, count: 30, seed: 12, minSeparation: 12)
        let base = SyntheticScene.starField(width: w, height: h, stars: stars, noise: 0.002, seed: 5)
        // Frames are shifted copies; each transform undoes the shift.
        let shifts: [(Int, Int)] = [(0, 0), (10, 5), (-6, 8)]
        var frames: [StackFrame] = []
        for (dx, dy) in shifts {
            var shifted = ImageBuffer(width: w, height: h, channels: 3)
            for y in 0..<h {
                for x in 0..<w {
                    let sx = x - dx, sy = y - dy
                    if sx >= 0 && sy >= 0 && sx < w && sy < h {
                        for c in 0..<3 { shifted[x, y, c] = base[sx, sy, c] }
                    }
                }
            }
            frames.append(StackFrame(image: shifted, transform: Matrix3([1, 0, Double(-dx), 0, 1, Double(-dy), 0, 0, 1])))
        }
        let overlap = Stacker.commonOverlap(frames: frames, fullWidth: w, fullHeight: h)
        print("computed overlap \(overlap)")
        // Intersect the three shifted rectangles analytically.
        var x0 = 0, y0 = 0, x1 = w, y1 = h
        for (dx, dy) in shifts {
            x0 = max(x0, dx); y0 = max(y0, dy)
            x1 = min(x1, w + dx); y1 = min(y1, h + dy)
        }
        #expect(Int(overlap.width) == x1 - x0)
        #expect(Int(overlap.height) == y1 - y0)
        var options = StackOptions(); options.method = .sigmaClipped; options.cropToOverlap = true
        let result = try Stacker.stack(frames: frames, fullWidth: w, fullHeight: h, options: options)
        print("stacked cropped size \(result.image.width)x\(result.image.height)")
        #expect(result.image.width == x1 - x0)
        #expect(result.image.height == y1 - y0)
        TestEvidence.write("crop overlap: \(result.image.width)x\(result.image.height), expected \(x1 - x0)x\(y1 - y0)", name: "crop.log")
    }

    @Test func backgroundNormalizationAlignsOffsets() throws {
        let w = 96, h = 64
        var a = ImageBuffer(width: w, height: h, channels: 3, value: 0.1)
        var b = ImageBuffer(width: w, height: h, channels: 3, value: 0.14)
        for i in 0..<a.count { b.pixels[i * 3 + 2] += 0.02 }
        let target = Calibration.background(a)
        b = Calibration.normalizeBackground(b, to: target)
        let bg = Calibration.background(b)
        print("background after normalization: \(bg)")
        #expect(abs(bg.x - target.x) < 1e-4)
        #expect(abs(bg.y - target.y) < 1e-4)
        #expect(abs(bg.z - target.z) < 1e-4)
    }
}
