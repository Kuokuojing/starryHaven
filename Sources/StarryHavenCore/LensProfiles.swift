import Foundation
import ImageIO
import CoreGraphics

public struct ImageMetadata: Sendable {
    public var make: String?
    public var model: String?
    public var lensModel: String?
    public var focalLength: Double?
    public var aperture: Double?
    public var focalLength35: Double?

    public init(make: String? = nil, model: String? = nil, lensModel: String? = nil,
                focalLength: Double? = nil, aperture: Double? = nil, focalLength35: Double? = nil) {
        self.make = make; self.model = model; self.lensModel = lensModel
        self.focalLength = focalLength; self.aperture = aperture; self.focalLength35 = focalLength35
    }

    public static func read(url: URL) -> ImageMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ImageMetadata()
        }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        func string(_ dict: [CFString: Any], _ key: CFString) -> String? {
            (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func number(_ dict: [CFString: Any], _ key: CFString) -> Double? {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let s = dict[key] as? String { return Double(s) }
            return nil
        }
        return ImageMetadata(
            make: string(tiff, kCGImagePropertyTIFFMake),
            model: string(tiff, kCGImagePropertyTIFFModel),
            lensModel: string(exif, kCGImagePropertyExifLensModel),
            focalLength: number(exif, kCGImagePropertyExifFocalLength),
            aperture: number(exif, kCGImagePropertyExifFNumber),
            focalLength35: number(exif, kCGImagePropertyExifFocalLenIn35mmFilm)
        )
    }

    public var summary: String {
        [make, model, lensModel, focalLength.map { String(format: "%.0fmm", $0) }, aperture.map { String(format: "f/%.1f", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

public struct RadialDistortion: Sendable {
    public enum Model: String, Sendable { case poly3, poly5, ptlens, adobe }
    public var model: Model
    public var a: Double
    public var b: Double
    public var c: Double
    public init(model: Model, a: Double, b: Double = 0, c: Double = 0) {
        self.model = model; self.a = a; self.b = b; self.c = c
    }
}

public struct VignetteCorrection: Sendable {
    public var k1: Double
    public var k2: Double
    public var k3: Double
    public init(k1: Double, k2: Double = 0, k3: Double = 0) {
        self.k1 = k1; self.k2 = k2; self.k3 = k3
    }
}

public struct LensCalibration: Sendable {
    public var distortion: RadialDistortion?
    public var vignetting: VignetteCorrection?
    public var source: String
    public init(distortion: RadialDistortion? = nil, vignetting: VignetteCorrection? = nil, source: String) {
        self.distortion = distortion; self.vignetting = vignetting; self.source = source
    }
}

public enum LensProfileMode: Sendable {
    case none
    case automatic
    case adobeLCP(URL)
}

// MARK: - lensfun

public struct LensfunLens: Sendable {
    public var maker: String
    public var model: String
    public var cropFactor: Double
    public var distortions: [(focal: Double, model: String, a: Double, b: Double, c: Double)]
    public var vignettings: [(focal: Double, aperture: Double, k1: Double, k2: Double, k3: Double)]
}

public final class LensfunDatabase {
    public static let shared = LensfunDatabase()
    public let lenses: [LensfunLens]
    public let directory: URL?

    public static var defaultDirectory: URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["LENSFUN_DB"] { candidates.append(URL(fileURLWithPath: env, isDirectory: true)) }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("Models/lensfun/v1", isDirectory: true))
            candidates.append(res.appendingPathComponent("lensfun/v1", isDirectory: true))
        }
        if let support = ModelLocator.applicationSupport {
            candidates.append(support.appendingPathComponent("Models/lensfun/v1", isDirectory: true))
            candidates.append(support.appendingPathComponent("lensfun/v1", isDirectory: true))
        }
        for c in candidates where FileManager.default.fileExists(atPath: c.path) { return c }
        return nil
    }

    private init() {
        let dir = Self.defaultDirectory
        directory = dir
        var parsed: [LensfunLens] = []
        if let dir = dir,
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "xml" {
                parsed.append(contentsOf: Self.parse(file: file))
            }
        }
        lenses = parsed
    }

    private static func parse(file: URL) -> [LensfunLens] {
        guard let doc = try? XMLDocument(contentsOf: file, options: []),
              let nodes = try? doc.nodes(forXPath: "//lens") else { return [] }
        var out: [LensfunLens] = []
        for node in nodes {
            guard let el = node as? XMLElement else { continue }
            let maker = el.elements(forName: "maker").first?.stringValue ?? ""
            let model = el.elements(forName: "model").first?.stringValue ?? ""
            let crop = Double(el.elements(forName: "cropfactor").first?.stringValue ?? "1") ?? 1
            var distortions: [(Double, String, Double, Double, Double)] = []
            var vignettes: [(Double, Double, Double, Double, Double)] = []
            if let cal = el.elements(forName: "calibration").first {
                for d in cal.elements(forName: "distortion") {
                    let focal = Double(d.attribute(forName: "focal")?.stringValue ?? "0") ?? 0
                    distortions.append((focal,
                                        d.attribute(forName: "model")?.stringValue ?? "poly3",
                                        Double(d.attribute(forName: "a")?.stringValue ?? "0") ?? 0,
                                        Double(d.attribute(forName: "b")?.stringValue ?? "0") ?? 0,
                                        Double(d.attribute(forName: "c")?.stringValue ?? "0") ?? 0))
                }
                for v in cal.elements(forName: "vignetting") {
                    let focal = Double(v.attribute(forName: "focal")?.stringValue ?? "0") ?? 0
                    let aperture = Double(v.attribute(forName: "aperture")?.stringValue ?? "0") ?? 0
                    vignettes.append((focal, aperture,
                                      Double(v.attribute(forName: "k1")?.stringValue ?? "0") ?? 0,
                                      Double(v.attribute(forName: "k2")?.stringValue ?? "0") ?? 0,
                                      Double(v.attribute(forName: "k3")?.stringValue ?? "0") ?? 0))
                }
            }
            if !model.isEmpty {
                out.append(LensfunLens(maker: maker, model: model, cropFactor: crop,
                                       distortions: distortions,
                                       vignettings: vignettes))
            }
        }
        return out
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "sony", with: "")
            .replacingOccurrences(of: "carl zeiss", with: "")
            .replacingOccurrences(of: "f/", with: "")
            .replacingOccurrences(of: "mm", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    public func bestMatch(for metadata: ImageMetadata) -> LensfunLens? {
        guard let lensName = metadata.lensModel, !lensName.isEmpty else { return nil }
        let target = Self.normalize(lensName)
        var best: (LensfunLens, Int)?
        for lens in lenses {
            let model = Self.normalize(lens.model)
            var score = 0
            if target == model { score = 1000 }
            else if target.contains(model) || model.contains(target) { score = 400 + min(model.count, target.count) }
            else {
                let targetTokens = Set(lensName.lowercased().split(separator: " ").map(String.init))
                let lensTokens = Set(lens.model.lowercased().split(separator: " ").map(String.init))
                score = targetTokens.intersection(lensTokens).count * 20
            }
            if let caller = metadata.make, !lens.maker.isEmpty,
               Self.normalize(caller).contains(Self.normalize(lens.maker)) || Self.normalize(lens.maker).contains(Self.normalize(caller)) {
                score += 5
            }
            if score > (best?.1 ?? 0) { best = (lens, score) }
        }
        guard let match = best, match.1 >= 20 else { return nil }
        return match.0
    }

    public func calibration(for lens: LensfunLens, focal: Double?, aperture: Double?) -> LensCalibration {
        var distortion: RadialDistortion?
        if let focal = focal ?? lens.distortions.first?.focal,
           let d = lens.distortions.min(by: { abs($0.focal - focal) < abs($1.focal - focal) }) {
            let model: RadialDistortion.Model = d.model == "ptlens" ? .ptlens : (d.model == "poly5" ? .poly5 : .poly3)
            distortion = RadialDistortion(model: model, a: d.a, b: d.b, c: d.c)
        }
        var vignette: VignetteCorrection?
        if !lens.vignettings.isEmpty {
            let f = focal ?? lens.vignettings[0].focal
            let a = aperture ?? lens.vignettings[0].aperture
            let best = lens.vignettings.min {
                abs($0.focal - f) + 0.4 * abs($0.aperture - a) <
                abs($1.focal - f) + 0.4 * abs($1.aperture - a)
            }
            if let best = best { vignette = VignetteCorrection(k1: best.k1, k2: best.k2, k3: best.k3) }
        }
        return LensCalibration(distortion: distortion, vignetting: vignette,
                               source: "Lensfun · \(lens.maker) \(lens.model)")
    }

    public func autoCalibration(metadata: ImageMetadata) -> LensCalibration? {
        guard let lens = bestMatch(for: metadata) else { return nil }
        let c = calibration(for: lens, focal: metadata.focalLength, aperture: metadata.aperture)
        if c.distortion == nil && c.vignetting == nil { return nil }
        return c
    }
}

// MARK: - Adobe LCP

public enum AdobeLCP {
    public static func parse(url: URL) -> LensCalibration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data, source: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(data: Data, source: String) -> LensCalibration? {
        guard let doc = try? XMLDocument(data: data, options: []),
              let nodes = try? doc.nodes(forXPath: "//*[local-name()='PerspectiveModel']"),
              let model = nodes.first as? XMLElement else { return nil }
        func attr(_ name: String) -> Double? {
            for a in model.attributes ?? [] {
                guard let an = a.name else { continue }
                let local = an.split(separator: ":").last.map(String.init) ?? an
                if local == name { return Double(a.stringValue ?? "") }
            }
            return nil
        }
        let k1 = attr("RadialDistortParam1") ?? 0
        let k2 = attr("RadialDistortParam2") ?? 0
        let k3 = attr("RadialDistortParam3") ?? 0
        var vignette: VignetteCorrection?
        if let vnodes = try? doc.nodes(forXPath: "//*[local-name()='VignetteModel']"),
           let v = vnodes.first as? XMLElement {
            func vattr(_ name: String) -> Double? {
                for a in v.attributes ?? [] {
                    guard let an = a.name else { continue }
                    let local = an.split(separator: ":").last.map(String.init) ?? an
                    if local == name { return Double(a.stringValue ?? "") }
                }
                return nil
            }
            if let v1 = vattr("VignetteModelParam1") {
                vignette = VignetteCorrection(k1: v1, k2: vattr("VignetteModelParam2") ?? 0,
                                              k3: vattr("VignetteModelParam3") ?? 0)
            }
        }
        return LensCalibration(distortion: RadialDistortion(model: .adobe, a: k1, b: k2, c: k3),
                               vignetting: vignette, source: "Adobe LCP · \(source)")
    }
}


/// Reads Adobe LCP profiles from an optional local profile archive. Filenames
/// narrow the search; the parsed model is what is applied.
public enum BundledAdobeLCP {
    private static let lock = NSLock()
    private static var cachedEntries: [String]?
    private static var cachedProfiles: [String: LensCalibration] = [:]

    public static var zipURL: URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["STARRYHAVEN_LCP_ZIP"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("LensProfiles.zip"))
            candidates.append(res.appendingPathComponent("Models/LensProfiles.zip"))
        }
        if let support = ModelLocator.applicationSupport {
            candidates.append(support.appendingPathComponent("LensProfiles.zip"))
            candidates.append(support.appendingPathComponent("Models/LensProfiles.zip"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func entries() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let cachedEntries = cachedEntries { return cachedEntries }
        guard let zip = zipURL else { cachedEntries = []; return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-Z1", zip.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let list = String(data: data, encoding: .utf8)?
                .split(separator: "\n").map(String.init)
                .filter { $0.lowercased().hasSuffix(".lcp") } ?? []
            cachedEntries = list
            return list
        } catch {
            cachedEntries = []
            return []
        }
    }

    private static func extract(_ entry: String) -> Data? {
        guard let zip = zipURL else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", zip.path, entry]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return data.isEmpty ? nil : data
        } catch { return nil }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "sony", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "mm", with: "")
            .replacingOccurrences(of: "f/", with: "f")
    }

    public static func find(metadata: ImageMetadata) -> LensCalibration? {
        guard let lens = metadata.lensModel, lens.count > 2, lens != "----" else { return nil }
        let target = normalize(lens)
        guard target.count > 6 else { return nil }
        let make = normalize(metadata.make ?? "")
        let candidates = entries().filter { entry in
            let n = normalize(entry)
            return (make.isEmpty || n.contains(make)) && (n.contains(target) || target.contains(n))
        }
        let subset = candidates.isEmpty ? entries().filter { normalize($0).contains(target) } : candidates
        for entry in subset.prefix(40) {
            lock.lock(); let cached = cachedProfiles[entry]; lock.unlock()
            if let cached = cached { return cached }
            guard let data = extract(entry), let profile = AdobeLCP.parse(data: data, source: entry) else { continue }
            lock.lock(); cachedProfiles[entry] = profile; lock.unlock()
            return profile
        }
        return nil
    }
}

// MARK: - Application

public enum LensProfileCorrection {
    public static func apply(_ calibration: LensCalibration, to image: ImageBuffer) -> ImageBuffer {
        var out = image
        if let v = calibration.vignetting {
            let cx = Double(image.width - 1) / 2, cy = Double(image.height - 1) / 2
            let maxR2 = cx * cx + cy * cy
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    let r2 = (dx * dx + dy * dy) / max(maxR2, 1)
                    let factor = 1 + v.k1 * r2 + v.k2 * r2 * r2 + v.k3 * r2 * r2 * r2
                    let gain = Float(1.0 / max(factor, 0.05))
                    for c in 0..<image.channels { out[x, y, c] = max(0, out[x, y, c] * gain) }
                }
            }
        }
        if let d = calibration.distortion {
            let cx = Double(image.width - 1) / 2, cy = Double(image.height - 1) / 2
            let halfDiag = hypot(cx, cy)
            var remapped = ImageBuffer(width: image.width, height: image.height, channels: image.channels)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    let r = hypot(dx, dy) / max(halfDiag, 1)
                    let r2 = r * r
                    let factor: Double
                    switch d.model {
                    case .poly3: factor = 1 - d.a * r2 - d.b * r2 * r2 - d.c * r2 * r2 * r2
                    case .poly5: factor = 1 - d.a * r2 - d.b * r2 * r2 - d.c * r2 * r2 * r2
                    case .ptlens: factor = d.a * r * r2 + d.b * r2 + d.c * r + 1 - d.a - d.b - d.c
                    case .adobe: factor = 1 + d.a * r2 + d.b * r2 * r2 + d.c * r2 * r2 * r2
                    }
                    let rr = r * factor
                    var sx = cx + (r > 1e-9 ? dx / r : 0) * rr * halfDiag
                    var sy = cy + (r > 1e-9 ? dy / r : 0) * rr * halfDiag
                    sx = min(max(sx, 0), Double(image.width - 1))
                    sy = min(max(sy, 0), Double(image.height - 1))
                    let x0 = Int(floor(sx)), y0 = Int(floor(sy))
                    let x1 = min(x0 + 1, image.width - 1), y1 = min(y0 + 1, image.height - 1)
                    let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                    for c in 0..<image.channels {
                        let v00 = out[x0, y0, c], v10 = out[x1, y0, c]
                        let v01 = out[x0, y1, c], v11 = out[x1, y1, c]
                        let top = v00 * (1 - fx) + v10 * fx
                        let bot = v01 * (1 - fx) + v11 * fx
                        remapped[x, y, c] = top * (1 - fy) + bot * fy
                    }
                }
            }
            out = remapped
        }
        return out
    }

    public static func calibration(for mode: LensProfileMode, metadata: ImageMetadata) -> LensCalibration? {
        switch mode {
        case .none: return nil
        case .automatic:
            if let c = LensfunDatabase.shared.autoCalibration(metadata: metadata) { return c }
            return BundledAdobeLCP.find(metadata: metadata)
        case .adobeLCP(let url): return AdobeLCP.parse(url: url)
        }
    }
}
