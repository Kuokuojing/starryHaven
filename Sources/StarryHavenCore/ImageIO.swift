import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import UniformTypeIdentifiers

public enum ImageIOError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case cannotDecode(String)
    case cannotEncode(String)
    case unsupportedFormat(String)

    public var description: String {
        switch self {
        case .cannotOpen(let s): return "Cannot open \(s)"
        case .cannotDecode(let s): return "Cannot decode \(s)"
        case .cannotEncode(let s): return "Cannot encode \(s)"
        case .unsupportedFormat(let s): return "Unsupported format \(s)"
        }
    }
}

public enum OutputFormat: String, CaseIterable, Sendable {
    case tiff16 = "TIFF (16-bit)"
    case fits32 = "FITS (32-bit float)"
    case png8 = "PNG (8-bit)"
    case jpeg8 = "JPEG (8-bit)"

    public var fileExtension: String {
        switch self {
        case .tiff16: return "tif"
        case .fits32: return "fits"
        case .png8: return "png"
        case .jpeg8: return "jpg"
        }
    }
}

public enum ImageLoader {
    public static let rawExtensions: Set<String> = [
        "arw", "sr2", "srf", "cr2", "cr3", "nef", "nrw", "dng", "raf", "orf", "rw2", "pef", "srw", "3fr", "erf", "mef", "mos", "iiq", "x3f"
    ]

    public static func isFITS(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["fit", "fits", "fts"].contains(ext) { return true }
        if let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            if let head = try? fh.read(upToCount: 6), String(data: head, encoding: .ascii)?.hasPrefix("SIMPLE") == true {
                return true
            }
        }
        return false
    }

    public static func isRAW(url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    public static func load(url: URL) throws -> ImageBuffer {
        if isFITS(url: url) {
            return try FITS.read(url: url)
        }
        if isRAW(url: url) {
            return try loadRAW(url: url)
        }
        return try loadCGImage(url: url)
    }

    public static func loadCGImage(url: URL) throws -> ImageBuffer {
        try decodeCGImage(url: url, linearize: true)
    }

    /// Loads an already display-referred image (PNG/JPEG/TIFF) without undoing
    /// its sRGB encoding. Used by the post-processing toolbox, whose third-party
    /// models expect stretched 0...1 input.
    public static func loadDisplayReferred(url: URL) throws -> ImageBuffer {
        if isFITS(url: url) || isRAW(url: url) {
            var img = try load(url: url)
            let maxV = img.statistics().max
            if maxV > 1.5 {
                let s = 1.0 / maxV
                for i in img.pixels.indices { img.pixels[i] *= s }
            }
            return PostProcess.stretch(img)
        }
        return try decodeCGImage(url: url, linearize: false)
    }

    private static func decodeCGImage(url: URL, linearize: Bool) throws -> ImageBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: true] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else {
            throw ImageIOError.cannotDecode(url.lastPathComponent)
        }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { throw ImageIOError.cannotDecode(url.lastPathComponent) }

        var rgba = [UInt16](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        guard let ctx = rgba.withUnsafeMutableBytes({ ptr in
            CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: colorSpace, bitmapInfo: info)
        }) else { throw ImageIOError.cannotDecode(url.lastPathComponent) }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var out = ImageBuffer(width: w, height: h, channels: 3)
        for i in 0..<(w * h) {
            let a = rgba[i * 4 + 3]
            let invA = a == 0 ? 1.0 : 65535.0 / Double(a)
            for c in 0..<3 {
                var v = Double(rgba[i * 4 + c]) * invA / 65535.0
                v = min(max(v, 0), 1)
                out.pixels[i * 3 + c] = linearize ? SRGB.decode(Float(v)) : Float(v)
            }
        }
        return out
    }

    public static func loadRAW(url: URL) throws -> ImageBuffer {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw ImageIOError.cannotDecode(url.lastPathComponent)
        }
        filter.isDraftModeEnabled = false
        if #available(macOS 26.0, *) {
            // Newer SDKs expose this property; KVC keeps older SDKs compiling.
            filter.setValue(true, forKey: "highlightRecoveryEnabled")
        }
        guard let output = filter.outputImage else {
            throw ImageIOError.cannotDecode(url.lastPathComponent)
        }
        let extent = output.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { throw ImageIOError.cannotDecode(url.lastPathComponent) }
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let ctx = CIContext(options: [
            .workingColorSpace: linear,
            .outputColorSpace: linear,
            .cacheIntermediates: false,
        ])
        var rgba = [Float](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { ptr in
            ctx.render(output,
                       toBitmap: ptr.baseAddress!,
                       rowBytes: w * 16,
                       bounds: extent,
                       format: .RGBAf,
                       colorSpace: linear)
        }
        var out = ImageBuffer(width: w, height: h, channels: 3)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                let v = rgba[i * 4 + c]
                out.pixels[i * 3 + c] = v.isFinite ? max(v, 0) : 0
            }
        }
        return out
    }

    /// Load an image and normalize it to [0,1] linear using its own min/max.
    /// Used by the post-processing tools for 16-bit display-referred TIFF/PNG inputs.
    public static func loadNormalized(url: URL) throws -> ImageBuffer {
        var img = try load(url: url)
        if isFITS(url: url) || isRAW(url: url) {
            let maxV = img.statistics().max
            if maxV > 1.5 {
                let s = 1.0 / maxV
                for i in img.pixels.indices { img.pixels[i] *= s }
            }
        }
        return img
    }
}

public enum ImageWriter {
    /// Saves linear data; CG formats get the sRGB transfer curve applied.
    public static func save(_ image: ImageBuffer, url: URL, format: OutputFormat, metadata: [String: String] = [:]) throws {
        switch format {
        case .tiff16: try saveCGImage(image, url: url, bits: 16, type: UTType.tiff.identifier, quality: 1.0, applyGamma: true)
        case .png8: try saveCGImage(image, url: url, bits: 8, type: UTType.png.identifier, quality: 1.0, applyGamma: true)
        case .jpeg8: try saveCGImage(image, url: url, bits: 8, type: UTType.jpeg.identifier, quality: 0.95, applyGamma: true)
        case .fits32: try FITS.write(image, url: url, metadata: metadata)
        }
    }

    /// Saves already display-referred data (stretched post-processing results)
    /// without applying the sRGB curve a second time.
    public static func saveDisplay(_ image: ImageBuffer, url: URL, format: OutputFormat, metadata: [String: String] = [:]) throws {
        switch format {
        case .tiff16: try saveCGImage(image, url: url, bits: 16, type: UTType.tiff.identifier, quality: 1.0, applyGamma: false)
        case .png8: try saveCGImage(image, url: url, bits: 8, type: UTType.png.identifier, quality: 1.0, applyGamma: false)
        case .jpeg8: try saveCGImage(image, url: url, bits: 8, type: UTType.jpeg.identifier, quality: 0.95, applyGamma: false)
        case .fits32: try FITS.write(image, url: url, metadata: metadata)
        }
    }

    public static func format(for url: URL) -> OutputFormat {
        switch url.pathExtension.lowercased() {
        case "fits", "fit", "fts": return .fits32
        case "png": return .png8
        case "jpg", "jpeg": return .jpeg8
        default: return .tiff16
        }
    }

    public static func cgImage(from image: ImageBuffer, bits: Int, applyGamma: Bool = true) -> CGImage? {
        let w = image.width, h = image.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        if bits == 16 {
            var rgba = [UInt16](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h) {
                for c in 0..<3 {
                    let linear = image.pixels[i * image.channels + c]
                    let v = applyGamma ? SRGB.encode(linear) : linear
                    rgba[i * 4 + c] = UInt16(min(max(v, 0), 1) * 65535.0 + 0.5)
                }
                rgba[i * 4 + 3] = 65535
            }
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            var buffer = rgba
            guard let ctx = buffer.withUnsafeMutableBytes({ ptr in
                CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: colorSpace, bitmapInfo: info)
            }) else { return nil }
            return ctx.makeImage()
        } else {
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h) {
                for c in 0..<3 {
                    let linear = image.pixels[i * image.channels + c]
                    let v = applyGamma ? SRGB.encode(linear) : linear
                    rgba[i * 4 + c] = UInt8(min(max(v, 0), 1) * 255.0 + 0.5)
                }
                rgba[i * 4 + 3] = 255
            }
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            var buffer = rgba
            guard let ctx = buffer.withUnsafeMutableBytes({ ptr in
                CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: colorSpace, bitmapInfo: info)
            }) else { return nil }
            return ctx.makeImage()
        }
    }

    private static func saveCGImage(_ image: ImageBuffer, url: URL, bits: Int, type: String, quality: Double, applyGamma: Bool) throws {
        guard let cg = cgImage(from: image, bits: bits, applyGamma: applyGamma) else {
            throw ImageIOError.cannotEncode(url.lastPathComponent)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw ImageIOError.cannotEncode(url.lastPathComponent)
        }
        var props: [CFString: Any] = [:]
        if type == UTType.jpeg.identifier {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if type == UTType.tiff.identifier {
            props[kCGImagePropertyTIFFCompression] = 5 // LZW
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageIOError.cannotEncode(url.lastPathComponent)
        }
    }
}
