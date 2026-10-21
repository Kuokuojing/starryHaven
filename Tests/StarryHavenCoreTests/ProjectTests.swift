import Foundation
import Testing
@testable import StarryHavenCore

@Suite("Project documents")
struct ProjectTests {
    @Test func projectRoundTripPreservesStackSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var project = StarryHavenProject()
        var stack = StackProjectState()
        stack.lights = ["/data/light-01.tif", "/data/light-02.tif"]
        stack.bias = ["/data/bias.tif"]
        stack.referenceIndex = 1
        stack.method = StackMethod.median.rawValue
        stack.lowSigma = 3
        stack.highSigma = 4
        stack.sceneMode = SceneMode.skyLand.rawValue
        stack.cropToOverlap = true
        stack.vignetteCorrection = 0.3
        stack.lensMode = "automatic"
        stack.outputPath = "/data/stack.tif"
        project.stack = stack
        project.workspace = "stack"
        var trails = TrailProjectState(); trails.frames = ["/data/t1.tif", "/data/t2.tif"]
        trails.method = StackMethod.maximum.rawValue; trails.removeAircraft = true
        project.trails = trails
        var pano = PanoramaProjectState(); pano.frames = ["/data/p1.tif", "/data/p2.tif"]; pano.referenceIndex = 1
        project.panorama = pano
        var tl = TimelapseProjectState(); tl.frames = ["/data/v1.tif"]; tl.deflickerWindow = 31; tl.fps = 30
        project.timelapse = tl
        var nb = NarrowbandProjectState(); nb.ha = "/data/ha.tif"; nb.oiii = "/data/oiii.tif"; nb.palette = NarrowbandPalette.hoo.rawValue
        project.narrowband = nb
        let url = dir.appendingPathComponent("project.starproject")
        try project.save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("starryhaven-project"))
        let loaded = try StarryHavenProject.load(from: url)
        #expect(loaded.workspace == "stack")
        #expect(loaded.stack?.lights == stack.lights)
        #expect(loaded.stack?.bias == stack.bias)
        #expect(loaded.stack?.referenceIndex == 1)
        #expect(loaded.stack?.method == StackMethod.median.rawValue)
        #expect(loaded.stack?.sceneMode == SceneMode.skyLand.rawValue)
        #expect(loaded.stack?.cropToOverlap == true)
        #expect(abs((loaded.stack?.vignetteCorrection ?? 0) - 0.3) < 1e-9)
        #expect(loaded.trails?.frames.count == 2)
        #expect(loaded.trails?.removeAircraft == true)
        #expect(loaded.panorama?.referenceIndex == 1)
        #expect(loaded.timelapse?.deflickerWindow == 31)
        #expect(loaded.timelapse?.fps == 30)
        #expect(loaded.narrowband?.palette == NarrowbandPalette.hoo.rawValue)
        TestEvidence.write("project round-trip: \(loaded.stack?.lights.count ?? 0) lights, ref \(loaded.stack?.referenceIndex ?? -1)", name: "project.log")
    }

    @Test func importsBareLegacySettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("legacy.json")
        let json = """
        {"lights": ["/x/a.tif", "/x/b.tif"], "referenceIndex": 1,
         "method": "中值", "sceneMode": "天地分离堆栈", "cropToOverlap": true}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        let project = try StarryHavenProject.load(from: url)
        #expect(project.workspace == "stack")
        #expect(project.stack?.lights.count == 2)
        #expect(project.stack?.referenceIndex == 1)
        #expect(project.stack?.cropToOverlap == true)
    }
}
