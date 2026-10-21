import Foundation
import Testing
@testable import StarryHavenCore

@Suite("End-to-end stack pipeline")
struct PipelineTests {
    @Test func selectedReferenceFrameDefinesOutputGeometry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stars = SyntheticScene.randomStars(width: 512, height: 512, count: 60, seed: 71, minSeparation: 16)
        let base = SyntheticScene.starField(width: 512, height: 512, stars: stars, noise: 0.002, seed: 3)
        // Two differently-sized crops of the same sky; the second is the reference.
        let cropA = base.cropped(x: 20, y: 30, width: 420, height: 320)
        let cropB = base.cropped(x: 10, y: 20, width: 460, height: 340)
        let aURL = dir.appendingPathComponent("a.tif")
        let bURL = dir.appendingPathComponent("b.tif")
        try ImageWriter.save(cropA, url: aURL, format: .tiff16)
        try ImageWriter.save(cropB, url: bURL, format: .tiff16)
        var request = StackRequest()
        request.lights = [aURL, bURL]
        request.referenceIndex = 1
        request.method = .sigmaClipped
        request.outputURL = dir.appendingPathComponent("ref1.tif")
        request.outputFormat = .tiff16
        let result = try StackPipeline.run(request)
        print("reference geometry \(result.image.width)x\(result.image.height), frames \(result.usedFrames)")
        #expect(result.image.width == 460)
        #expect(result.image.height == 340)
        #expect(result.usedFrames == 2)
        TestEvidence.write("reference index 1 output: \(result.image.width)x\(result.image.height), frames=\(result.usedFrames)", name: "pipeline-reference.log")
    }

    @Test func skyLandStackKeepsReferenceGround() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = 480, h = 360, horizon = 170
        let scene = SyntheticScene.horizonScene(width: w, height: h, horizonY: horizon, seed: 123)
        var files: [URL] = []
        let shifts = [(0, 0), (4, -3), (-5, 2), (7, 4)]
        for (i, shift) in shifts.enumerated() {
            var frame = ImageBuffer(width: w, height: h, channels: 3)
            for y in 0..<h {
                for x in 0..<w {
                    let sx = x - shift.0, sy = y - shift.1
                    if sx >= 0 && sy >= 0 && sx < w && sy < h {
                        for c in 0..<3 { frame[x, y, c] = scene.image[sx, sy, c] }
                    }
                }
            }
            var rng = SyntheticScene.Random(seed: UInt64(600 + i))
            for j in 0..<frame.pixels.count { frame.pixels[j] = max(0, frame.pixels[j] + Float(rng.gaussian() * 0.0015)) }
            let url = dir.appendingPathComponent(String(format: "h-%02d.tif", i))
            try ImageWriter.save(frame, url: url, format: .tiff16)
            files.append(url)
        }
        // Manual black/white sky mask (white above the horizon).
        var maskImage = ImageBuffer(width: w, height: h, channels: 3)
        for y in 0..<h {
            for x in 0..<w {
                let v: Float = y < horizon ? 1 : 0
                for c in 0..<3 { maskImage[x, y, c] = v }
            }
        }
        let maskURL = dir.appendingPathComponent("mask.png")
        try ImageWriter.saveDisplay(maskImage, url: maskURL, format: .png8)

        func run(mode: SceneMode, name: String) throws -> StackPipelineResult {
            var request = StackRequest()
            request.lights = files
            request.referenceIndex = 0
            request.method = .sigmaClipped
            request.sceneMode = mode
            request.manualMaskURL = maskURL
            request.outputURL = dir.appendingPathComponent(name)
            request.outputFormat = .fits32
            return try StackPipeline.run(request)
        }
        let separated = try run(mode: .skyLand, name: "separated.fits")
        #expect(separated.usedFrames == 4)
        #expect(separated.image.width == w && separated.image.height == h)

        let reference = try ImageLoader.load(url: files[0])
        var groundChanged = 0
        var skyChanged = 0
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    let d = abs(Double(separated.image[x, y, c] - reference[x, y, c]))
                    if y >= horizon {
                        if d > 1e-3 { groundChanged += 1 }
                    } else if d > 0.002 {
                        skyChanged += 1
                    }
                }
            }
        }
        print("sky/land separation: groundChanged=\(groundChanged), skyChanged=\(skyChanged)")
        #expect(groundChanged == 0)
        #expect(skyChanged > 1000)
        TestEvidence.write("sky/land stack: groundChanged=\(groundChanged) skyChanged=\(skyChanged) frames=\(separated.usedFrames)", name: "pipeline-skyland.log")

        let full = try run(mode: .fullFrame, name: "full.fits")
        #expect(full.image.width == w && full.image.height == h)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("separated.fits").path))
    }
}
