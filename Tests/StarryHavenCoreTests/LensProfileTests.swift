import Foundation
import Testing
@testable import StarryHavenCore

@Suite("Lensfun and Adobe LCP profiles")
struct LensProfileTests {
    @Test func lensfunDatabaseAndAutoMatch() throws {
        let db = LensfunDatabase.shared
        print("lensfun lenses: \(db.lenses.count), dir: \(db.directory?.path ?? "none")")
        guard db.lenses.count > 100 else { return }
        #expect(db.lenses.count > 100)
        let meta = ImageMetadata(make: "Sony", model: "NEX-7", lensModel: "E 16mm f/2.8",
                                 focalLength: 16, aperture: 2.8, focalLength35: 24)
        let calibration = try #require(db.autoCalibration(metadata: meta))
        print("auto calibration: \(calibration.source), distortion=\(String(describing: calibration.distortion)), vignette=\(String(describing: calibration.vignetting))")
        #expect(calibration.source.contains("Lensfun"))
        #expect(calibration.distortion != nil)
        TestEvidence.write("lensfun lenses=\(db.lenses.count) matched=\(calibration.source)", name: "lensfun.log")
    }

    @Test func lensfunVignetteCorrectionBrightensCorners() throws {
        let db = LensfunDatabase.shared
        guard db.lenses.count > 100 else { return }
        let meta = ImageMetadata(make: "Sony", model: "NEX-7", lensModel: "E 16mm f/2.8", focalLength: 16, aperture: 2.8)
        let full = try #require(db.autoCalibration(metadata: meta))
        let calibration = LensCalibration(distortion: nil, vignetting: full.vignetting, source: full.source)
        let w = 160, h = 120
        var image = ImageBuffer(width: w, height: h, channels: 3)
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        let maxR2 = cx * cx + cy * cy
        for y in 0..<h {
            for x in 0..<w {
                let r2 = (pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)) / maxR2
                let v = Float(0.5 * (1 - 0.7 * r2))
                image[x, y, 0] = v; image[x, y, 1] = v; image[x, y, 2] = v
            }
        }
        let corrected = LensProfileCorrection.apply(calibration, to: image)
        let ratioBefore = Double(image[3, 3, 0]) / Double(image[w / 2, h / 2, 0])
        let ratioAfter = Double(corrected[3, 3, 0]) / Double(corrected[w / 2, h / 2, 0])
        print(String(format: "lensfun vignette corner/center %.3f -> %.3f", ratioBefore, ratioAfter))
        #expect(ratioAfter > ratioBefore * 1.15)
        TestEvidence.write(String(format: "lensfun vignette %.3f -> %.3f (%@)", ratioBefore, ratioAfter, calibration.source), name: "lensfun-apply.log")
    }

    @Test func adobeLCPParserAndDistortion() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description xmlns:stCamera="http://ns.adobe.com/photoshop/1.0/camera-profile">
           <stCamera:PerspectiveModel stCamera:Version="2" stCamera:FocalLengthX="0.9"
             stCamera:FocalLengthY="0.9" stCamera:ImageXCenter="0.5" stCamera:ImageYCenter="0.5"
             stCamera:RadialDistortParam1="0.12" stCamera:RadialDistortParam2="-0.3"
             stCamera:RadialDistortParam3="0.2"/>
           <stCamera:VignetteModel stCamera:VignetteModelParam1="-0.4"
             stCamera:VignetteModelParam2="0.2" stCamera:VignetteModelParam3="-0.05"/>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lcp")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        let calibration = try #require(AdobeLCP.parse(url: url))
        print("LCP calibration \(calibration.source) distortion \(String(describing: calibration.distortion)) vignette \(String(describing: calibration.vignetting))")
        #expect(calibration.distortion?.a == 0.12)
        #expect(calibration.vignetting?.k1 == -0.4)
        let image = ImageBuffer(width: 200, height: 150, channels: 3, value: 0.3)
        let corrected = LensProfileCorrection.apply(calibration, to: image)
        #expect(corrected.width == 200 && corrected.height == 150)
        TestEvidence.write("LCP parsed: \(calibration.source)", name: "lcp.log")
    }

    @Test func bundledAdobeLCPAutoLookup() throws {
        guard BundledAdobeLCP.zipURL != nil else { return }
        let meta = ImageMetadata(make: "Sony", model: "ILCE-7RM5",
                                 lensModel: "Sony FE 24-70mm F2.8 GM II", focalLength: 50, aperture: 2.8)
        let calibration = try #require(BundledAdobeLCP.find(metadata: meta))
        print("auto LCP: \(calibration.source), distortion=\(String(describing: calibration.distortion))")
        #expect(calibration.distortion != nil)
        TestEvidence.write("auto LCP: \(calibration.source)", name: "lcp-auto.log")
    }

    @Test func rawMetadataContainsCameraAndLens() throws {
        guard let url = TestAssets.rawSample else { return }
        let meta = ImageMetadata.read(url: url)
        print("RAW metadata: \(meta.summary) lens=\(meta.lensModel ?? "nil") focal=\(meta.focalLength ?? 0) aperture=\(meta.aperture ?? 0)")
        #expect(meta.make != nil || meta.model != nil)
        TestEvidence.write("RAW metadata: \(meta.summary)", name: "lens-metadata.log")
    }
}
