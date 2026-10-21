import Foundation
import StarryHavenCore

enum TestAssets {
    /// Optional real camera RAW used by integration tests. Point
    /// `STARRYHAVEN_RAW_SAMPLE` at a local file to enable those checks.
    static var rawSample: URL? {
        guard let path = ProcessInfo.processInfo.environment["STARRYHAVEN_RAW_SAMPLE"], !path.isEmpty else {
            return nil
        }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}

enum TestEvidence {
    static var directory: URL? {
        if let p = ProcessInfo.processInfo.environment["STARRYHAVEN_SCRATCH"] {
            let url = URL(fileURLWithPath: p, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return nil
    }

    static func write(_ text: String, name: String) {
        guard let dir = directory else { return }
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        print("[evidence] \(name): \(text)")
    }

    static func save(_ image: ImageBuffer, name: String, format: OutputFormat = .png8) {
        guard let dir = directory else { return }
        let url = dir.appendingPathComponent(name)
        try? ImageWriter.save(image, url: url, format: format)
    }

    static func copy(_ url: URL, name: String) {
        guard let dir = directory else { return }
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    static func saveDisplay(_ image: ImageBuffer, name: String, format: OutputFormat = .png8) {
        guard let dir = directory else { return }
        let url = dir.appendingPathComponent(name)
        try? ImageWriter.saveDisplay(image, url: url, format: format)
    }
}

func makeSimilarity(scale: Double, rotationDegrees: Double, tx: Double, ty: Double) -> Matrix3 {
    let a = rotationDegrees * Double.pi / 180
    let s = scale
    return Matrix3([s * cos(a), -s * sin(a), tx, s * sin(a), s * cos(a), ty, 0, 0, 1])
}

func alignedStarRMS(reference: StarField, warped: StarField, tolerance: Double = 3.0) -> (rms: Double, matched: Int) {
    var used = Set<Int>()
    var sum = 0.0
    var count = 0
    for r in reference.stars {
        var best = -1
        var bestD = tolerance
        for (i, w) in warped.stars.enumerated() where !used.contains(i) {
            let d = hypot(r.x - w.x, r.y - w.y)
            if d < bestD { bestD = d; best = i }
        }
        if best >= 0 {
            used.insert(best)
            sum += bestD * bestD
            count += 1
        }
    }
    return (count > 0 ? sqrt(sum / Double(count)) : .infinity, count)
}

func backgroundNoise(_ image: ImageBuffer, region: (x: Int, y: Int, w: Int, h: Int)) -> Double {
    var values: [Float] = []
    for y in region.y..<(region.y + region.h) {
        for x in region.x..<(region.x + region.w) {
            values.append(image.pixels[image.index(x, y, 0)])
        }
    }
    let mean = values.reduce(0) { $0 + Double($1) } / Double(values.count)
    var variance = 0.0
    for v in values { variance += pow(Double(v) - mean, 2) }
    return sqrt(variance / Double(max(values.count - 1, 1)))
}

func maxDifference(_ a: ImageBuffer, _ b: ImageBuffer, mask: [Float]? = nil) -> Double {
    var m = 0.0
    for i in 0..<min(a.pixels.count, b.pixels.count) {
        if let mask = mask, mask[i / a.channels] < 0.5 { continue }
        m = max(m, abs(Double(a.pixels[i]) - Double(b.pixels[i])))
    }
    return m
}

func meanDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
    var s = 0.0
    for i in 0..<min(a.pixels.count, b.pixels.count) { s += abs(Double(a.pixels[i]) - Double(b.pixels[i])) }
    return s / Double(a.pixels.count)
}
