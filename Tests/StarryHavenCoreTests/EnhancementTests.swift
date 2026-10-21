import Foundation
import Testing
@testable import StarryHavenCore

@Suite("Artistic enhancement")
struct EnhancementTests {
    func texturedImage(width: Int = 256, height: Int = 192) -> ImageBuffer {
        var img = ImageBuffer(width: width, height: height, channels: 3)
        for y in 0..<height {
            for x in 0..<width {
                let texture = 0.03 * sin(Double(x) * 0.7) * cos(Double(y) * 0.9)
                let glow = 0.20 * exp(-pow((Double(x) - 120) / 60, 2) - pow((Double(y) - 90) / 50, 2))
                let v = Float(0.15 + texture + glow)
                img[x, y, 0] = v; img[x, y, 1] = v * 0.95; img[x, y, 2] = v * 0.9
            }
        }
        return img
    }

    func highPassStd(_ img: ImageBuffer) -> Double {
        let blur = PostProcess.gaussianBlur(img, sigma: 2)
        var sum = 0.0, sum2 = 0.0, n = 0.0
        for i in 0..<img.count {
            let d = Double(img.pixels[i * 3] - blur.pixels[i * 3])
            sum += d; sum2 += d * d; n += 1
        }
        let mean = sum / n
        return sqrt(max(sum2 / n - mean * mean, 0))
    }

    @Test func localContrastAndStructureIncreaseDetail() {
        let img = texturedImage()
        var e = EnhancementOptions()
        e.localContrast = 0.8
        let local = PostProcess.enhance(img, options: e)
        let before = highPassStd(img), after = highPassStd(local)
        print(String(format: "local contrast high-pass std %.5f -> %.5f", before, after))
        #expect(after > before * 1.2)
        e = EnhancementOptions()
        e.structure = 0.8
        e.structureRadius = 24
        let structured = PostProcess.enhance(img, options: e)
        #expect(highPassStd(structured) > before * 1.05)
        TestEvidence.write(String(format: "local contrast %.5f -> %.5f", before, after), name: "enhance-local.log")
    }

    @Test func skylightReducesBlueHaze() {
        var img = ImageBuffer(width: 96, height: 64, channels: 3)
        for i in 0..<img.count {
            img.pixels[i * 3] = 0.20
            img.pixels[i * 3 + 1] = 0.25
            img.pixels[i * 3 + 2] = 0.50
        }
        var e = EnhancementOptions()
        e.skylight = 1
        let out = PostProcess.enhance(img, options: e)
        print("skylight blue \(img[10, 10, 2]) -> \(out[10, 10, 2]), red \(img[10, 10, 0]) -> \(out[10, 10, 0])")
        #expect(out[10, 10, 2] < img[10, 10, 2] * 0.9)
        #expect(abs(out[10, 10, 0] - img[10, 10, 0]) < 1e-6)
        TestEvidence.write("skylight blue \(img[10, 10, 2]) -> \(out[10, 10, 2])", name: "enhance-skylight.log")
    }

    @Test func starTrailGlowAddsHaloWithoutClipping() {
        var img = ImageBuffer(width: 128, height: 96, channels: 3, value: 0.02)
        for x in 20..<100 { for y in 45..<49 { img[x, y, 0] = 0.9; img[x, y, 1] = 0.9; img[x, y, 2] = 0.9 } }
        let glow = PostProcess.starTrailGlow(img, amount: 2.0, radius: 4)
        let haloBefore = img[60, 53, 0]
        let haloAfter = glow[60, 53, 0]
        print(String(format: "glow halo %.4f -> %.4f, core %.2f", haloBefore, haloAfter, glow[60, 47, 0]))
        #expect(haloAfter > haloBefore * 2)
        #expect(glow[60, 47, 0] <= 1.0001)
        TestEvidence.write(String(format: "star-trail glow halo %.4f -> %.4f", haloBefore, haloAfter), name: "enhance-glow.log")
    }

    @Test func skyOnlyEnhancementLeavesGroundUntouched() throws {
        guard ModelLocator.skySeg != nil, ModelLocator.onnxRuntime != nil else { return }
        let scene = SyntheticScene.horizonScene(width: 480, height: 320, horizonY: 145, seed: 15)
        let mask = try SkySegmenter.segment(image: scene.image)
        var e = EnhancementOptions()
        e.localContrast = 0.8
        e.skylight = 0.6
        let out = PostProcess.enhance(scene.image, options: e, mask: mask)
        var changed = 0
        for i in 0..<scene.ground.count where scene.ground[i] > 0.5 {
            for c in 0..<3 where out.pixels[i * 3 + c] != scene.image.pixels[i * 3 + c] { changed += 1 }
        }
        print("sky-only enhancement ground changes \(changed)")
        #expect(changed == 0)
        TestEvidence.write("sky-only enhancement ground changes=\(changed)", name: "enhance-sky.log")
    }
}
