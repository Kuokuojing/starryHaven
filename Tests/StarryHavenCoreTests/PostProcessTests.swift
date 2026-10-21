import Foundation
import Testing
@testable import StarryHavenCore

@Suite("Third-party post-processing and sky protection")
struct PostProcessTests {
    @Test func skySegAndManualMaskMatchHorizon() throws {
        guard ModelLocator.skySeg != nil, ModelLocator.onnxRuntime != nil else { return }
        let scene = SyntheticScene.horizonScene(width: 640, height: 480, horizonY: 220, seed: 99)
        let mask = try SkySegmenter.segment(image: scene.image)
        var skyTruth = [Float](repeating: 0, count: scene.ground.count)
        for i in 0..<skyTruth.count { skyTruth[i] = scene.ground[i] > 0.5 ? 0 : 1 }
        let iou = mask.iou(against: skyTruth)
        print(String(format: "SkySeg ioU against synthetic horizon: %.4f", iou))
        #expect(iou >= 0.85)
        let skyFraction = Double(mask.mask.reduce(0) { $0 + $1 }) / Double(mask.mask.count)
        #expect(abs(skyFraction - Double(220) / 480.0) < 0.05)

        let manual = SkyComposite.manualMask(image: {
            var m = ImageBuffer(width: 640, height: 480, channels: 3)
            for y in 0..<480 { for x in 0..<640 {
                let v: Float = y < 220 ? 1 : 0
                m[x, y, 0] = v; m[x, y, 1] = v; m[x, y, 2] = v
            } }
            return m
        }())
        #expect(manual.iou(against: skyTruth) > 0.99)

        // A sky-only stretch must leave every ground pixel bit-identical.
        let stretched = PostProcess.stretch(scene.image)
        let composited = SkyComposite.skyOnly(original: scene.image, effect: stretched, mask: mask)
        var groundChanged = 0
        var skyChanged = 0
        for i in 0..<scene.ground.count {
            for c in 0..<3 {
                if scene.ground[i] > 0.5 {
                    if composited.pixels[i * 3 + c] != scene.image.pixels[i * 3 + c] { groundChanged += 1 }
                } else if abs(composited.pixels[i * 3 + c] - scene.image.pixels[i * 3 + c]) > 1e-4 {
                    skyChanged += 1
                }
            }
        }
        print("ground pixels changed by sky-only stretch: \(groundChanged), sky pixels changed: \(skyChanged)")
        #expect(groundChanged == 0)
        #expect(skyChanged > 1000)
        TestEvidence.write("""
        SkySeg model: \(ModelLocator.artifactDescription(ModelLocator.skySeg))
        SkySeg IoU: \(iou)
        sky fraction: \(skyFraction)
        ground pixels changed: \(groundChanged)
        sky pixels changed: \(skyChanged)
        """, name: "skyseg.log")
        TestEvidence.save(PostProcess.stretch(scene.image), name: "horizon.png")
        var maskImg = ImageBuffer(width: 640, height: 480, channels: 3)
        for i in 0..<mask.mask.count { for c in 0..<3 { maskImg.pixels[i * 3 + c] = mask.mask[i] } }
        TestEvidence.saveDisplay(maskImg, name: "skyseg-mask.png")
    }

    @Test func starNetRemovesAndRecomposesStars() throws {
        guard ModelLocator.starNet2 != nil else { return }
        let w = 512, h = 512
        let stars = SyntheticScene.randomStars(width: w, height: h, count: 70, seed: 404, minSeparation: 14)
        var linear = SyntheticScene.starField(width: w, height: h, stars: stars, background: 0.03,
                                              backgroundGradient: 0.01, noise: 0.002, seed: 8)
        SyntheticScene.addNebula(to: &linear, center: (300, 260), radius: 70, brightness: 0.06)
        let display = PostProcess.stretch(linear)
        let inputStars = StarDetector.detect(image: display)
        let result = try StarSeparation.separate(image: display, stride: 256)
        let starlessStars = StarDetector.detect(image: result.starless)
        let reduction = 1 - Double(starlessStars.stars.count) / Double(max(inputStars.stars.count, 1))
        print("StarNet2 backend: \(result.backend)")
        print("stars input \(inputStars.stars.count), starless \(starlessStars.stars.count), reduction \(reduction)")
        #expect(inputStars.stars.count > 30)
        #expect(reduction >= 0.7)

        let recomposed = StarSeparation.recompose(starless: result.starless, stars: result.stars, amount: 1.0)
        let recomposedStars = StarDetector.detect(image: recomposed)
        let rms = alignedStarRMS(reference: inputStars, warped: recomposedStars, tolerance: 2.0)
        // Flux restoration over matched centroids (nearest neighbour, 2 px).
        var used = Set<Int>()
        var fluxBefore = 0.0, fluxAfter = 0.0
        for a in inputStars.stars {
            var best = -1
            var bestD = 2.0
            for (i, b) in recomposedStars.stars.enumerated() where !used.contains(i) {
                let d = hypot(a.x - b.x, a.y - b.y)
                if d < bestD { bestD = d; best = i }
            }
            if best >= 0 {
                used.insert(best)
                fluxBefore += a.flux
                fluxAfter += recomposedStars.stars[best].flux
            }
        }
        let fluxRatio = fluxAfter / max(fluxBefore, 1e-9)
        print(String(format: "recomposed stars %d, centroid RMS %.3f, flux ratio %.4f", recomposedStars.stars.count, rms.rms, fluxRatio))
        #expect(recomposedStars.stars.count >= Int(Double(inputStars.stars.count) * 0.9))
        #expect(rms.rms < 1.0)
        #expect(abs(fluxRatio - 1) < 0.02)
        let maxDiff = maxDifference(display, recomposed)
        print(String(format: "recomposition max diff %.6f", maxDiff))
        #expect(maxDiff < 1e-4)
        TestEvidence.write("""
        backend: \(result.backend)
        model: \(ModelLocator.artifactDescription(ModelLocator.starNet2))
        input stars: \(inputStars.stars.count)
        starless stars: \(starlessStars.stars.count)
        reduction: \(reduction)
        recomposed stars: \(recomposedStars.stars.count)
        recomposition RMS: \(rms.rms)
        recomposition flux ratio: \(fluxRatio)
        matched stars: \(used.count)
        """, name: "starnet.log")
        TestEvidence.saveDisplay(display, name: "starnet-input.png")
        TestEvidence.saveDisplay(result.starless, name: "starnet-starless.png")
        TestEvidence.saveDisplay(recomposed, name: "starnet-recomposed.png")
        TestEvidence.saveDisplay(result.stars, name: "starnet-stars.png")
    }

    @Test func deepSNRReducesNoiseAndKeepsStructure() throws {
        guard ModelLocator.deepSNR != nil else { return }
        let w = 512, h = 512
        let stars = SyntheticScene.randomStars(width: w, height: h, count: 50, seed: 777, minSeparation: 18)
        var linear = SyntheticScene.starField(width: w, height: h, stars: stars, background: 0.04,
                                              noise: 0.006, seed: 21)
        SyntheticScene.addNebula(to: &linear, center: (260, 256), radius: 80, brightness: 0.10)
        let display = PostProcess.stretch(linear)

        func highFrequencyNoise(_ img: ImageBuffer, region: (x: Int, y: Int, w: Int, h: Int)) -> Double {
            let blur = PostProcess.gaussianBlur(img, sigma: 1.6)
            var sum = 0.0, sum2 = 0.0, n = 0.0
            for y in region.y..<(region.y + region.h) {
                for x in region.x..<(region.x + region.w) {
                    let d = Double(img[x, y, 0] - blur[x, y, 0])
                    sum += d; sum2 += d * d; n += 1
                }
            }
            let mean = sum / n
            return sqrt(max(sum2 / n - mean * mean, 0))
        }
        let region = (x: 350, y: 40, w: 120, h: 100)
        let before = highFrequencyNoise(display, region: region)
        let denoised = try DeepSNR.denoise(image: display, stride: 256)
        let after = highFrequencyNoise(denoised, region: region)
        let ratio = after / before
        print(String(format: "DeepSNR high-frequency noise before %.5f after %.5f ratio %.3f", before, after, ratio))
        #expect(ratio <= 0.8)

        func centerMean(_ img: ImageBuffer) -> Double {
            var s = 0.0, n = 0.0
            for y in 246..<266 { for x in 250..<270 {
                s += Double(img[x, y, 0]); n += 1
            } }
            return s / n
        }
        let c0 = centerMean(display), c1 = centerMean(denoised)
        print(String(format: "nebula center before %.5f after %.5f (%.2f%%)", c0, c1, (c1 / c0 - 1) * 100))
        #expect(abs(c1 / c0 - 1) < 0.05)
        TestEvidence.write(String(format: "DeepSNR %@\nnoise ratio: %.3f\ncenter before: %.5f\nafter: %.5f", ModelLocator.artifactDescription(ModelLocator.deepSNR), ratio, c0, c1), name: "deepsnr.log")
        TestEvidence.saveDisplay(denoised, name: "deepsnr-denoised.png")
    }

    @Test func whiteBalanceAndBackgroundExtractionWork() throws {
        var image = ImageBuffer(width: 128, height: 96, channels: 3)
        for y in 0..<96 {
            for x in 0..<128 {
                let g = Double(y) / 95.0
                image[x, y, 0] = Float(0.20 + 0.10 * g) * 1.4
                image[x, y, 1] = Float(0.20 + 0.10 * g)
                image[x, y, 2] = Float(0.20 + 0.10 * g) * 0.7
            }
        }
        var wbOptions = WhiteBalanceOptions(); wbOptions.mode = .auto
        let balanced = PostProcess.whiteBalance(image, options: wbOptions)
        let bg = Calibration.background(balanced)
        print("auto white balance background \(bg)")
        #expect(abs(bg.x - bg.y) < 0.01)
        #expect(abs(bg.z - bg.y) < 0.01)

        let flattened = PostProcess.backgroundBalance(image, grid: 8, degree: 2)
        let top = flattened[10, 3, 0], bottom = flattened[10, 92, 0]
        print("background extraction top \(top) bottom \(bottom)")
        #expect(abs(Double(top - bottom)) < 0.01)
    }

    @Test func starReductionLowersStellarFlux() throws {
        let w = 384, h = 256
        let stars = SyntheticScene.randomStars(width: w, height: h, count: 30, seed: 66, minSeparation: 20)
        var image = SyntheticScene.starField(width: w, height: h, stars: stars, background: 0.08, noise: 0.001, seed: 2)
        image = PostProcess.stretch(image)
        let before = StarDetector.detect(image: image)
        let reduced = PostProcess.starReduction(image, amount: 0.85, softening: 0, radiusScale: 1.0)
        let after = StarDetector.detect(image: reduced)
        let beforeFlux = before.stars.reduce(0) { $0 + $1.flux }
        let afterFlux = after.stars.reduce(0) { $0 + $1.flux }
        print(String(format: "star flux before %.1f after %.1f, stars %d -> %d", beforeFlux, afterFlux, before.stars.count, after.stars.count))
        #expect(afterFlux < beforeFlux * 0.8)
        let bgBefore = Calibration.background(image)
        let bgAfter = Calibration.background(reduced)
        #expect(abs(Double(bgBefore.x - bgAfter.x)) < 0.01)
    }
}
