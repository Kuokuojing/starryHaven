import Foundation
import Testing
import ImageIO
@testable import StarryHavenCore

func imageDepth(_ url: URL) -> Int {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 0 }
    if let depth = props[kCGImagePropertyDepth] as? Int { return depth }
    if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
       let bits = tiff["BitsPerSample" as CFString] as? Int { return bits }
    return 0
}

func fitsHeader(_ url: URL) -> FITS.HeaderInfo? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? FITS.readHeader(data)
}


func make2DFITS(width: Int, height: Int, bitpix: Int, bzero: Double = 0, values: [Float]) -> Data {
    func card(_ key: String, _ value: String) -> String {
        let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        return (k + "= " + value).padding(toLength: 80, withPad: " ", startingAt: 0)
    }
    var header = ""
    header += card("SIMPLE", "T")
    header += card("BITPIX", String(format: "%20d", bitpix))
    header += card("NAXIS", String(format: "%20d", 2))
    header += card("NAXIS1", String(format: "%20d", width))
    header += card("NAXIS2", String(format: "%20d", height))
    if bzero != 0 { header += card("BZERO", String(format: "%20.1f", bzero)) }
    if bzero != 0 { header += card("BSCALE", String(format: "%20.1f", 1.0)) }
    header += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    let hp = (2880 - header.count % 2880) % 2880
    header += String(repeating: " ", count: hp)
    var data = Data(header.utf8)
    for v in values {
        switch bitpix {
        case 16:
            let stored = UInt16(bitPattern: Int16(v - Float(bzero)))
            data.append(UInt8(stored >> 8)); data.append(UInt8(stored & 0xFF))
        case -32:
            var be = v.bitPattern.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        default:
            fatalError("unsupported fixture bitpix")
        }
    }
    let pad = (2880 - data.count % 2880) % 2880
    if pad > 0 { data.append(Data(repeating: 0, count: pad)) }
    return data
}

@Suite("Image I/O")
struct IOTests {
    func sampleImage() -> ImageBuffer {
        let w = 96, h = 64
        var img = ImageBuffer(width: w, height: h, channels: 3)
        for y in 0..<h {
            for x in 0..<w {
                img[x, y, 0] = Float(0.02 + 0.8 * Double(x) / Double(w))
                img[x, y, 1] = Float(0.03 + 0.6 * Double(y) / Double(h))
                img[x, y, 2] = Float(0.01 + 0.5 * Double((x + y) % 17) / 17.0)
            }
        }
        return img
    }

    @Test func tiffPngJpegRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = sampleImage()
        let tiff = dir.appendingPathComponent("image.tif")
        let png = dir.appendingPathComponent("image.png")
        let jpg = dir.appendingPathComponent("image.jpg")
        try ImageWriter.save(img, url: tiff, format: .tiff16)
        try ImageWriter.save(img, url: png, format: .png8)
        try ImageWriter.save(img, url: jpg, format: .jpeg8)

        let tiffDepth = imageDepth(tiff)
        let pngDepth = imageDepth(png)
        let jpgDepth = imageDepth(jpg)
        print("bit depths tiff=\(tiffDepth) png=\(pngDepth) jpeg=\(jpgDepth)")
        #expect(tiffDepth == 16)
        #expect(pngDepth == 8)
        #expect(jpgDepth == 8)

        let tiffBack = try ImageLoader.load(url: tiff)
        let pngBack = try ImageLoader.load(url: png)
        let jpgBack = try ImageLoader.load(url: jpg)
        #expect(tiffBack.width == img.width && tiffBack.height == img.height)
        #expect(pngBack.width == img.width && jpgBack.width == img.width)
        let tiffErr = maxDifference(img, tiffBack)
        let pngErr = maxDifference(img, pngBack)
        let jpgErr = meanDifference(img, jpgBack)
        print(String(format: "round-trip max error tiff %.5f png %.5f jpeg mean %.5f", tiffErr, pngErr, jpgErr))
        TestEvidence.write(String(format: "tiff16 depth=%d maxerr=%.6f\npng8 depth=%d maxerr=%.6f\njpeg8 depth=%d meanerr=%.6f",
                                  tiffDepth, tiffErr, pngDepth, pngErr, jpgDepth, jpgErr), name: "io-formats.log")
        #expect(tiffErr < 0.002)
        #expect(pngErr < 0.01)
        #expect(jpgErr < 0.02)
        TestEvidence.copy(tiff, name: "io-image-16bit.tif")
        TestEvidence.copy(png, name: "io-image.png")
        TestEvidence.copy(jpg, name: "io-image.jpg")
    }

    @Test func fitsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = sampleImage()
        let url = dir.appendingPathComponent("image.fits")
        try ImageWriter.save(img, url: url, format: .fits32)
        let header = try #require(fitsHeader(url))
        print("FITS BITPIX \(header.bitpix), size \(header.width)x\(header.height), planes \(header.planes)")
        #expect(header.bitpix == -32)
        #expect(header.width == img.width && header.height == img.height && header.planes == 3)
        let back = try ImageLoader.load(url: url)
        #expect(back.width == img.width && back.height == img.height)
        let err = maxDifference(img, back)
        print(String(format: "FITS round-trip max error %.9f", err))
        #expect(err < 1e-6)
        TestEvidence.write("FITS BITPIX=-32 dims=\(header.width)x\(header.height) maxerr=\(err)", name: "io-fits.log")
        TestEvidence.copy(url, name: "io-image.fits")
    }

    @Test func twoDimensionalFITSInputsDecode() throws {
        let w = 8, h = 6
        var values: [Float] = []
        for y in 0..<h {
            for x in 0..<w { values.append(Float(0.01 + 0.01 * Double(y * w + x))) }
        }
        let floatData = make2DFITS(width: w, height: h, bitpix: -32, values: values)
        let floatURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fits")
        try floatData.write(to: floatURL)
        let header = try #require(try? FITS.readHeader(floatData))
        print("2D FITS NAXIS=\(header.naxis) planes=\(header.planes) size \(header.width)x\(header.height)")
        #expect(header.naxis == 2)
        #expect(header.planes == 1)
        let decoded = try FITS.read(data: floatData)
        #expect(decoded.width == w && decoded.height == h)
        for i in 0..<(w * h) {
            #expect(abs(decoded.pixels[i * 3] - values[i]) < 1e-6)
            #expect(decoded.pixels[i * 3 + 1] == decoded.pixels[i * 3])
        }
        let loaded = try ImageLoader.load(url: floatURL)
        #expect(abs(loaded[7, 5, 0] - values[47]) < 1e-6)

        // BITPIX=16 with the conventional unsigned BZERO=32768.
        let shortValues: [Float] = (0..<(10 * 8)).map { Float(1000 + $0 * 7) }
        let shortData = make2DFITS(width: 10, height: 8, bitpix: 16, bzero: 32768, values: shortValues)
        let shortDecoded = try FITS.read(data: shortData)
        #expect(shortDecoded.width == 10 && shortDecoded.height == 8)
        for i in 0..<shortValues.count {
            #expect(abs(shortDecoded.pixels[i * 3] - shortValues[i]) < 0.001)
        }
        // A 100x100 2D mono file must not be treated as two planes/truncated.
        let bigValues = (0..<10_000).map { Float($0) / 10_000 }
        let bigData = make2DFITS(width: 100, height: 100, bitpix: -32, values: bigValues)
        let big = try FITS.read(data: bigData)
        #expect(big.width == 100 && big.height == 100)
        #expect(abs(big.pixels[9999 * 3] - bigValues[9999]) < 1e-6)
        TestEvidence.write("2D FITS -32 and 16-bit decoded \(w)x\(h) and 10x8 plus 100x100 with correct values", name: "io-fits-2d.log")
    }

    @Test func integerFITSNormalizesForProcessing() throws {
        let w = 4, h = 3
        let values: [Float] = [1000, 2000, 4000, 8000, 16000, 32000,
                               1200, 2400, 4800, 9600, 19200, 38400]
        let data = make2DFITS(width: w, height: h, bitpix: 16, bzero: 32768, values: values)
        let raw = try FITS.read(data: data)
        #expect(raw.pixels[0] > 100)
        let normalized = try FITS.read(data: data, normalizeIntegerData: true)
        #expect(abs(normalized.pixels[0] - 1000.0 / 65535.0) < 1e-6)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fits")
        try data.write(to: url)
        let loaded = try ImageLoader.load(url: url)
        #expect(abs(loaded.pixels[0] - 1000.0 / 65535.0) < 1e-6)
        TestEvidence.write("16-bit FITS normalized for processing", name: "io-fits-normalize.log")
    }

    @Test func fitsWriterPadsToRecordBoundary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = sampleImage()
        let url = dir.appendingPathComponent("padded.fits")
        try ImageWriter.save(img, url: url, format: .fits32)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        print("FITS file size \(size), remainder \(size % 2880)")
        #expect(size % 2880 == 0)
        let header = try #require(fitsHeader(url))
        #expect(header.naxis == 3 && header.planes == 3)
        #expect(header.width == img.width && header.height == img.height)
        let back = try FITS.read(url: url)
        #expect(maxDifference(img, back) < 1e-6)
        TestEvidence.write("FITS writer size=\(size) mod2880=\(size % 2880) naxis=3 planes=3 roundtrip maxerr<1e-6", name: "io-fits-padding.log")
    }

    @Test func cameraRawDecodes() throws {
        guard let url = TestAssets.rawSample else { return }
        let img = try ImageLoader.load(url: url)
        let stats = img.statistics()
        print(String(format: "RAW %dx%d min %.5f max %.5f mean %.5f", img.width, img.height, stats.min, stats.max, stats.mean))
        #expect(img.width > 1000 && img.height > 1000)
        #expect(stats.max > 0.1)
        #expect(stats.mean > 0.0001)
        #expect(img.pixels.count == img.width * img.height * 3)
        TestEvidence.write(String(format: "RAW %dx%d mean %.5f max %.5f", img.width, img.height, stats.mean, stats.max), name: "io-raw.log")
    }

    @Test func manualMaskHonorsBlackWhite() throws {
        var image = ImageBuffer(width: 16, height: 16, channels: 3)
        for y in 0..<16 { for x in 0..<16 {
            let v: Float = y < 8 ? 1 : 0
            image[x, y, 0] = v; image[x, y, 1] = v; image[x, y, 2] = v
        } }
        let mask = SkyComposite.manualMask(image: image)
        var truth = [Float](repeating: 0, count: 256)
        for y in 0..<8 { for x in 0..<16 { truth[y * 16 + x] = 1 } }
        #expect(mask.iou(against: truth) > 0.999)
    }
}
