import Foundation

public enum NarrowbandPalette: String, CaseIterable, Sendable {
    case sho = "SHO（哈勃）"
    case hoo = "HOO（双窄带）"
    case hso = "HSO"
}

public struct NarrowbandRequest: Sendable {
    public var ha: URL?
    public var oiii: URL?
    public var sii: URL?
    public var palette: NarrowbandPalette = .sho
    public var applyStretch = true
    public var removeStars = false
    public var outputURL: URL?
    public var outputFormat: OutputFormat?
    public init() {}
}

public struct NarrowbandResult: Sendable {
    public var image: ImageBuffer
    public var preview: ImageBuffer
    public var log: [String]
    public var outputURL: URL?
}

public enum NarrowbandError: Error, CustomStringConvertible {
    case missingChannel(String)
    case sizeMismatch
    public var description: String {
        switch self {
        case .missingChannel(let s): return "缺少\(s)通道"
        case .sizeMismatch: return "窄带通道尺寸不一致"
        }
    }
}

public enum NarrowbandComposer {
    public static func channel(from url: URL, stretch: Bool) throws -> (values: [Float], width: Int, height: Int) {
        var image = try ImageLoader.load(url: url)
        if image.channels == 3 {
            let lum = image.luminance()
            var mono = ImageBuffer(width: image.width, height: image.height, channels: 3)
            for i in 0..<lum.count {
                mono.pixels[i * 3] = lum[i]; mono.pixels[i * 3 + 1] = lum[i]; mono.pixels[i * 3 + 2] = lum[i]
            }
            image = mono
        }
        _ = stretch
        return (image.channel(0), image.width, image.height)
    }

    public static func run(_ request: NarrowbandRequest,
                           progress: ((Double, String) -> Void)? = nil) throws -> NarrowbandResult {
        var log: [String] = []
        guard let haURL = request.ha else { throw NarrowbandError.missingChannel("Ha") }
        guard let oiiiURL = request.oiii else { throw NarrowbandError.missingChannel("OIII") }
        if request.palette == .sho && request.sii == nil { throw NarrowbandError.missingChannel("SII") }
        let ha = try channel(from: haURL, stretch: request.applyStretch)
        progress?(0.2, "读取 Ha")
        let oiii = try channel(from: oiiiURL, stretch: request.applyStretch)
        progress?(0.4, "读取 OIII")
        let sii: (values: [Float], width: Int, height: Int)?
        if let url = request.sii {
            sii = try channel(from: url, stretch: request.applyStretch)
        } else {
            sii = nil
        }
        progress?(0.55, "读取 SII")
        guard ha.width == oiii.width, ha.height == oiii.height else { throw NarrowbandError.sizeMismatch }
        if let s = sii, (s.width != ha.width || s.height != ha.height) { throw NarrowbandError.sizeMismatch }

        var haValues = ha.values
        var oiiiValues = oiii.values
        var siiValues = sii?.values ?? [Float](repeating: 0, count: ha.values.count)
        if request.applyStretch {
            // Background subtraction plus a common normalization keeps the
            // relative strength of the three emission lines.
            let bgH = RGBMath.median(haValues), bgO = RGBMath.median(oiiiValues), bgS = RGBMath.median(siiValues)
            for i in 0..<haValues.count {
                haValues[i] = max(0, haValues[i] - bgH)
                oiiiValues[i] = max(0, oiiiValues[i] - bgO)
                siiValues[i] = max(0, siiValues[i] - bgS)
            }
            let commonMax = max(haValues.max() ?? 1, max(oiiiValues.max() ?? 1, siiValues.max() ?? 1))
            if commonMax > 1e-6 {
                for i in 0..<haValues.count {
                    haValues[i] /= commonMax; oiiiValues[i] /= commonMax; siiValues[i] /= commonMax
                }
            }
        }
        var out = ImageBuffer(width: ha.width, height: ha.height, channels: 3)
        for i in 0..<(ha.width * ha.height) {
            let h = haValues[i]
            let o = oiiiValues[i]
            let s = siiValues[i]
            switch request.palette {
            case .sho:
                out.pixels[i * 3] = s
                out.pixels[i * 3 + 1] = h
                out.pixels[i * 3 + 2] = o
            case .hoo:
                out.pixels[i * 3] = h
                out.pixels[i * 3 + 1] = o * 0.85
                out.pixels[i * 3 + 2] = o
            case .hso:
                out.pixels[i * 3] = h
                out.pixels[i * 3 + 1] = s
                out.pixels[i * 3 + 2] = o
            }
        }
        if request.applyStretch {
            out = PostProcess.stretch(out)
        }
        log.append("通道组合：\(request.palette.rawValue)，\(ha.width)×\(ha.height)")
        progress?(0.7, "通道组合")
        if request.removeStars {
            let separated = try StarSeparation.separate(image: out, stride: 256) { p in
                progress?(0.7 + 0.2 * p, "星点分离")
            }
            out = separated.starless
            log.append("StarNet2 去星：\(separated.backend)")
        }
        if let url = request.outputURL {
            try ImageWriter.saveDisplay(out, url: url, format: request.outputFormat ?? ImageWriter.format(for: url))
            log.append("已写入 \(url.path)")
        }
        progress?(1.0, "完成")
        return NarrowbandResult(image: out, preview: out, log: log, outputURL: request.outputURL)
    }
}
