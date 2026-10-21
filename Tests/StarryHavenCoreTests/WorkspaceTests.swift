import Foundation
import Testing
import AVFoundation
@testable import StarryHavenCore

@Suite("Star trails, timelapse, panorama, narrowband")
struct WorkspaceTests {
    func starFrame(width: Int, height: Int, starX: Double, starY: Double, seed: UInt64) -> ImageBuffer {
        var img = ImageBuffer(width: width, height: height, channels: 3)
        for y in 0..<height {
            for x in 0..<width {
                let ground = 0.03 + 0.02 * Double((x / 13) % 3) + 0.01 * sin(Double(y) * 0.2)
                for c in 0..<3 { img[x, y, c] = Float(ground) }
            }
        }
        let spec = SyntheticScene.StarSpec(x: starX, y: starY, peak: 0.95, sigma: 1.6)
        SyntheticScene.addStar(to: &img, spec)
        var rng = SyntheticScene.Random(seed: seed)
        for i in 0..<img.pixels.count { img.pixels[i] = max(0, img.pixels[i] + Float(rng.gaussian() * 0.001)) }
        return img
    }

    @Test func fixedStarTrailsFormLongTracks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = 320, h = 200
        var urls: [URL] = []
        for i in 0..<20 {
            let frame = starFrame(width: w, height: h, starX: 40 + Double(i) * 4, starY: 100, seed: UInt64(10 + i))
            let url = dir.appendingPathComponent(String(format: "t-%02d.tif", i))
            try ImageWriter.save(frame, url: url, format: .tiff16)
            urls.append(url)
        }
        var request = StarTrailRequest()
        request.lights = urls
        request.method = .maximum
        request.landscape = .fixed
        request.outputURL = dir.appendingPathComponent("trails.tif")
        let result = try StarTrailPipeline.run(request)
        let out = result.image
        var trailPixels = 0
        for x in 30..<150 where out[x, 100, 0] > 0.35 { trailPixels += 1 }
        let single = try ImageLoader.load(url: urls[0])
        var singlePixels = 0
        for x in 30..<150 where single[x, 100, 0] > 0.35 { singlePixels += 1 }
        print("trail pixels in stack \(trailPixels), in single frame \(singlePixels)")
        #expect(trailPixels > 45)
        #expect(singlePixels < 15)
        TestEvidence.write("star trail stack: trail pixels=\(trailPixels), single frame=\(singlePixels)", name: "startrails.log")
        TestEvidence.save(result.preview, name: "startrails.png")
    }

    @Test func aircraftLineMaskRemovesSatelliteTrack() throws {
        let w = 320, h = 200
        var frame = starFrame(width: w, height: h, starX: 80, starY: 50, seed: 99)
        SyntheticScene.addSatelliteTrail(to: &frame, from: (20, 180), to: (300, 20), brightness: 0.5, width: 0.7)
        let mask = AircraftTrail.mask(in: frame)
        let masked = mask.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) }
        print("aircraft mask pixels \(masked)")
        #expect(masked > 200)
        var changed = 0
        for y in 20..<180 {
            let x = Int(20 + (300 - 20) * (180 - y) / 160)
            if mask[y * w + x] > 0.5 { changed += 1 }
        }
        #expect(changed > 100)
        TestEvidence.write("aircraft line mask: \(masked) pixels", name: "startrails-aircraft.log")
    }

    @Test func timelapseDeflickerAndVideoExport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = 96, h = 64
        let gains: [Float] = [0.6, 1.4, 0.75, 1.25, 0.8, 1.2, 0.9, 1.1]
        var frames: [ImageBuffer] = []
        for (i, g) in gains.enumerated() {
            var f = ImageBuffer(width: w, height: h, channels: 3, value: 0.2)
            for p in 0..<f.pixels.count { f.pixels[p] = min(1, f.pixels[p] * g) }
            var rng = SyntheticScene.Random(seed: UInt64(300 + i))
            for p in 0..<f.pixels.count { f.pixels[p] = max(0, f.pixels[p] + Float(rng.gaussian() * 0.004)) }
            frames.append(f)
            let url = dir.appendingPathComponent(String(format: "f-%02d.tif", i))
            try ImageWriter.save(f, url: url, format: .tiff16)
        }
        func variation(_ fs: [ImageBuffer]) -> Double {
            let levels = fs.map { Double(Calibration.background($0).x) }
            let mean = levels.reduce(0, +) / Double(levels.count)
            let sd = sqrt(levels.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(levels.count))
            return sd / max(mean, 1e-9)
        }
        let before = variation(frames)
        let fixed = TimelapseProcessor.deflicker(frames, window: 5)
        let after = variation(fixed)
        print(String(format: "timelapse flicker before %.4f after %.4f", before, after))
        #expect(after < before * 0.6)

        let video = dir.appendingPathComponent("timelapse.mp4")
        try TimelapseProcessor.writeVideo(frames: fixed, url: video, fps: 12, applyGamma: true)
        let size = (try FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0
        let duration = AVURLAsset(url: video).duration.seconds
        print("video bytes \(size), duration \(duration)")
        #expect(size > 1000)
        #expect(duration > 0.1)
        TestEvidence.write(String(format: "timelapse flicker %.4f -> %.4f, video %d bytes, %.2fs", before, after, size, duration), name: "timelapse.log")
    }

    @Test func panoramaStitchesOverlappingFields() throws {
        let base = SyntheticScene.starField(width: 600, height: 300,
                                            stars: SyntheticScene.randomStars(width: 600, height: 300, count: 70, seed: 501, minSeparation: 14),
                                            noise: 0.001, seed: 7)
        let left = base.cropped(x: 0, y: 0, width: 400, height: 300)
        let right = base.cropped(x: 200, y: 0, width: 400, height: 300)
        let result = try PanoramaStitcher.stitch(frames: [left, right], referenceIndex: 1)
        print("panorama canvas \(result.canvas.0)x\(result.canvas.1)")
        #expect(result.canvas.0 >= 590 && result.canvas.0 <= 603)
        #expect(result.canvas.1 >= 298 && result.canvas.1 <= 303)
        #expect(result.image.statistics().max > 0.3)
        TestEvidence.write("panorama canvas \(result.canvas.0)x\(result.canvas.1)", name: "panorama.log")
        TestEvidence.save(PostProcess.stretch(result.image), name: "panorama.png")
    }

    @Test func narrowbandChannelMapping() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func mono(_ base: Float, _ url: URL) throws {
            var img = ImageBuffer(width: 64, height: 64, channels: 3)
            for i in 0..<img.count {
                let v = base
                img.pixels[i * 3] = v; img.pixels[i * 3 + 1] = v; img.pixels[i * 3 + 2] = v
            }
            try ImageWriter.save(img, url: url, format: .tiff16)
        }
        let haURL = dir.appendingPathComponent("ha.tif")
        let oiiiURL = dir.appendingPathComponent("oiii.tif")
        let siiURL = dir.appendingPathComponent("sii.tif")
        try mono(0.30, haURL); try mono(0.10, oiiiURL); try mono(0.60, siiURL)
        var request = NarrowbandRequest()
        request.ha = haURL; request.oiii = oiiiURL; request.sii = siiURL
        request.palette = .sho
        request.applyStretch = false
        let sho = try NarrowbandComposer.run(request)
        let p = sho.image.pixel(x: 10, y: 10)
        print("SHO pixel \(p.x),\(p.y),\(p.z)")
        #expect(abs(sho.image[10, 10, 0] - 0.60) < 0.03)
        #expect(abs(sho.image[10, 10, 1] - 0.30) < 0.03)
        #expect(abs(sho.image[10, 10, 2] - 0.10) < 0.03)
        var hoo = request
        hoo.palette = .hoo
        hoo.sii = nil
        let hooResult = try NarrowbandComposer.run(hoo)
        #expect(abs(hooResult.image[10, 10, 0] - 0.30) < 0.03)
        #expect(abs(hooResult.image[10, 10, 2] - 0.10) < 0.03)
        TestEvidence.write("narrowband SHO mapping verified", name: "narrowband.log")
        TestEvidence.save(sho.image, name: "narrowband-sho.png")
    }

    @Test func lensVignetteCorrectionBrightensCorners() throws {
        let w = 128, h = 96
        var img = ImageBuffer(width: w, height: h, channels: 3)
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        let maxR2 = cx * cx + cy * cy
        for y in 0..<h {
            for x in 0..<w {
                let r2 = (pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)) / maxR2
                let v = Float(0.5 * (1 - 0.5 * r2))
                img[x, y, 0] = v; img[x, y, 1] = v; img[x, y, 2] = v
            }
        }
        var options = LensCorrectionOptions()
        options.vignette = 1.0
        let corrected = LensCorrection.apply(img, options: options)
        let centerBefore = Double(img[w / 2, h / 2, 0])
        let cornerBefore = Double(img[2, 2, 0])
        let centerAfter = Double(corrected[w / 2, h / 2, 0])
        let cornerAfter = Double(corrected[2, 2, 0])
        print(String(format: "vignette corner/center %.3f -> %.3f", cornerBefore / centerBefore, cornerAfter / centerAfter))
        #expect(cornerAfter / centerAfter > cornerBefore / centerBefore * 1.3)
        TestEvidence.write(String(format: "lens vignette ratio %.3f -> %.3f", cornerBefore / centerBefore, cornerAfter / centerAfter), name: "lens.log")
    }
}
